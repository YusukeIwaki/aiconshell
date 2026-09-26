# frozen_string_literal: true

require "db_helper"
require "open3"
require "rbconfig"
require "timeout"

# These tests deliberately do not request RailsFixture's transactional db
# fixture: PostgreSQL advisory locks belong to real, independent sessions.
module DeliveryLockTestSupport
  class RecordingPool
    attr_reader :backend_pids

    def initialize(pool)
      @pool = pool
      @backend_pids = Queue.new
    end

    def checkout
      connection = @pool.checkout
      @backend_pids << connection.raw_connection.backend_pid
      connection
    end

    def checkin(connection) = @pool.checkin(connection)
    def remove(connection) = @pool.remove(connection)
  end

  module_function

  def pop(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def join(thread)
    unless thread.join(5)
      thread.kill
      thread.join
      raise "delivery lock test worker did not finish"
    end
    thread.value
  end

  def with_held_lock(pool: ActiveRecord::Base.connection_pool)
    ready = Queue.new
    release = Queue.new
    holder = Thread.new do
      result = EventLogging::DeliveryLock.with_lock(pool:) do
        ready << :entered
        release.pop
        :delivered
      end
      ready << :finished
      result
    rescue StandardError => error
      ready << error
      raise
    end
    holder.report_on_exception = false

    begin
      state = pop(ready)
      raise state if state.is_a?(Exception)
      raise "delivery lock test holder did not acquire the lock" unless state == :entered

      yield
    ensure
      release << true
      join(holder)
    end
  end

  def try_lock(connection)
    connection.exec_query("SELECT pg_try_advisory_lock(#{EventLogging::DeliveryLock::LOCK_KEY})").rows[0][0]
  end

  def unlock(connection)
    connection.exec_query("SELECT pg_advisory_unlock(#{EventLogging::DeliveryLock::LOCK_KEY})").rows[0][0]
  end
end

test("delivery lock lets only one real PostgreSQL session enter and skips a contender immediately") do
  pool = DeliveryLockTestSupport::RecordingPool.new(ActiveRecord::Base.connection_pool)
  contender = nil
  DeliveryLockTestSupport.with_held_lock(pool:) do
    holder_pid = DeliveryLockTestSupport.pop(pool.backend_pids)
    entered = Queue.new
    contender = Thread.new do
      EventLogging::DeliveryLock.with_lock(pool:) { entered << true }
    end
    # This completes while the holder is still inside its block. A blocking
    # advisory lock would time out here instead of skipping the duplicate job.
    expect(DeliveryLockTestSupport.join(contender)).to eq(nil)
    contender_pid = DeliveryLockTestSupport.pop(pool.backend_pids)
    expect(contender_pid).not_to eq(holder_pid)
    expect(entered.empty?).to eq(true)
  end
ensure
  if contender&.alive?
    contender.kill
    contender.join
  end
end

test("delivery lock keeps its session idle without a transaction during remote work") do
  pool = DeliveryLockTestSupport::RecordingPool.new(ActiveRecord::Base.connection_pool)
  DeliveryLockTestSupport.with_held_lock(pool:) do
    holder_pid = DeliveryLockTestSupport.pop(pool.backend_pids)
    ActiveRecord::Base.connection_pool.with_connection do |observer|
      expect(observer.raw_connection.backend_pid).not_to eq(holder_pid)
      row = observer.exec_query(<<~SQL).first
        SELECT state, xact_start, backend_xid::text,
               EXISTS(SELECT 1 FROM pg_locks WHERE pid = #{holder_pid}
                      AND locktype = 'advisory' AND granted) AS holds_lock
        FROM pg_stat_activity WHERE pid = #{holder_pid}
      SQL
      expect(row["state"]).to eq("idle")
      expect(row["xact_start"]).to eq(nil)
      expect(row["backend_xid"]).to eq(nil)
      expect(row["holds_lock"]).to eq(true)
      expect(observer.transaction_open?).to eq(false)
    end
  end
end

test("delivery lock returns the block result and releases for another session") do
  ActiveRecord::Base.connection_pool.with_connection do |observer|
    result = EventLogging::DeliveryLock.with_lock { { "delivered" => 3 } }
    expect(result).to eq({ "delivered" => 3 })
    acquired = DeliveryLockTestSupport.try_lock(observer)
    begin
      expect(acquired).to eq(true)
    ensure
      DeliveryLockTestSupport.unlock(observer) if acquired
    end
  end
end

test("delivery lock releases after a delivery exception and preserves that exception") do
  ActiveRecord::Base.connection_pool.with_connection do |observer|
    expect do
      EventLogging::DeliveryLock.with_lock { raise ArgumentError, "delivery failed" }
    end.to raise_error(ArgumentError, /delivery failed/)
    acquired = DeliveryLockTestSupport.try_lock(observer)
    begin
      expect(acquired).to eq(true)
    ensure
      DeliveryLockTestSupport.unlock(observer) if acquired
    end
  end
end

test("delivery lock does not reuse a session for reentrant calls on the same thread") do
  inner_entered = false
  result = EventLogging::DeliveryLock.with_lock do
    EventLogging::DeliveryLock.with_lock { inner_entered = true }
  end
  expect(result).to eq(nil)
  expect(inner_entered).to eq(false)
end

test("delivery lock acquisitions bypass an enabled ActiveRecord query cache") do
  ActiveRecord::Base.cache do
    expect(EventLogging::DeliveryLock.with_lock { :first }).to eq(:first)
    DeliveryLockTestSupport.with_held_lock do
      expect(EventLogging::DeliveryLock.with_lock { :unprotected }).to eq(nil)
    end
  end
end

test("delivery lock coordinates separate Ruby processes and is released when its owner dies") do
  child_script = <<~RUBY
    ActiveRecord::Base.establish_connection(JSON.parse(ENV.fetch("AICONSHELL_LOCK_TEST_DATABASE")))
    require ARGV.fetch(0)
    EventLogging::DeliveryLock.with_lock do
      STDOUT.puts("locked")
      STDOUT.flush
      STDIN.read
    end
  RUBY
  child_env = {
    "AICONSHELL_LOCK_TEST_DATABASE" => JSON.generate(ActiveRecord::Base.connection_db_config.configuration_hash)
  }
  helper = Rails.root.join("app/services/event_logging/delivery_lock.rb").to_s

  Open3.popen3(child_env, RbConfig.ruby, "-rbundler/setup", "-ractive_record", "-rjson",
              "-e", child_script, helper) do |input, output, _errors, process|
    begin
      expect(Timeout.timeout(5) { output.gets }).to eq("locked\n")
      expect(EventLogging::DeliveryLock.with_lock { :overlap }).to eq(nil)

      # Bypass Ruby ensure blocks: only termination of the actual PostgreSQL
      # session can make the same lock available to the surviving process.
      Process.kill("KILL", process.pid)
      status = Timeout.timeout(5) { process.value }
      expect(status.signaled?).to eq(true)
      recovered = Timeout.timeout(5) do
        loop do
          result = EventLogging::DeliveryLock.with_lock { :recovered }
          break result if result

          sleep 0.01
        end
      end
      expect(recovered).to eq(:recovered)
    ensure
      input.close unless input.closed?
      if process.alive?
        Process.kill("KILL", process.pid)
        Timeout.timeout(5) { process.value }
      end
    end
  end
end
