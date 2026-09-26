# frozen_string_literal: true

require "json"
require "logger"
require "securerandom"
require "stringio"
require "timeout"

# Scoped helpers for the issue #10 task-request suites. Keeps UUID/API-token
# constants and HTTP/thread helpers out of the global namespace.
module TaskRequestTestSupport
  UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  API_TOKEN = "test-admin-api-token-9f2c4a"

  BARRIER_TIMEOUT = 15
  THREAD_JOIN_TIMEOUT = 15

  class FakeTriageJob
    attr_reader :calls, :error

    def initialize(error: nil)
      @calls = []
      @error = error
    end

    def perform_later(*arguments)
      @calls << arguments
      raise @error if @error

      true
    end
  end

  def self.with_api_token(token)
    old = ENV["ADMIN_API_TOKEN"]
    ENV["ADMIN_API_TOKEN"] = token
    yield
  ensure
    ENV["ADMIN_API_TOKEN"] = old
  end

  def self.api_post(http, payload, key:, token: API_TOKEN, content_type: "application/json", path: "/api/admin/task_requests")
    http.header "Host", AdminTestSupport::HOST
    http.header "Authorization", token ? "Bearer #{token}" : nil
    http.header "Idempotency-Key", key
    http.header "Content-Type", content_type
    body = payload.is_a?(String) ? payload : JSON.generate(payload)
    http.post path, body
  end

  def self.api_get(http, id, token: API_TOKEN)
    http.header "Host", AdminTestSupport::HOST
    http.header "Authorization", token ? "Bearer #{token}" : nil
    http.get "/api/admin/task_requests/#{id}"
  end

  def self.extract_key(body, name)
    body[/#{Regexp.escape(name)}" value="([^"]+)"/, 1] ||
      body[/name="#{Regexp.escape(name)}" value="([^"]+)"/, 1]
  end

  # Bounded barrier pop: fails instead of hanging the suite.
  def self.pop_bounded(queue, timeout: BARRIER_TIMEOUT)
    Timeout.timeout(timeout) { queue.pop }
  end

  # Bounded thread join with cleanup. Returns the thread value, or raises on
  # timeout after killing the stuck worker.
  def self.join_bounded(thread, timeout: THREAD_JOIN_TIMEOUT)
    result = thread.join(timeout)
    return thread.value if result

    stop_thread(thread)
    raise "worker thread did not finish within #{timeout}s"
  end

  def self.stop_thread(thread)
    return unless thread

    thread.kill if thread.alive?
    raise "worker thread did not stop" unless thread.join(2)
  end

  # Observe a real PostgreSQL lock wait before releasing the winning
  # transaction. Thread liveness or a sleep does not prove contention.
  def self.wait_for_blocked_session(blocked_pid, blocker_pid)
    blocked_pid = Integer(blocked_pid)
    blocker_pid = Integer(blocker_pid)
    raise "race requires independent sessions" if blocked_pid == blocker_pid

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BARRIER_TIMEOUT
    ActiveRecord::Base.connection_pool.with_connection do |observer|
      loop do
        blocked = observer.select_value("SELECT #{blocker_pid} = ANY(pg_blocking_pids(#{blocked_pid}))")
        return if blocked
        raise "loser did not contend on the winner's transaction" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    end
  end

  def self.with_captured_debug_logs
    logger = Rails.logger
    original_levels = logger.broadcasts.to_h { |sink| [sink, sink.level] }
    io = StringIO.new
    capture = ActiveSupport::Logger.new(io)
    capture.level = Logger::DEBUG
    # Rails middleware and LogSubscribers retain this logger instance.
    # Replacing Rails.logger alone can leave a falsely empty capture.
    logger.broadcast_to(capture)
    logger.level = Logger::DEBUG
    yield io
    raise "HTTP logging control line was not captured" unless io.string.include?("Processing by ")
  ensure
    logger&.stop_broadcasting_to(capture) if capture
    original_levels&.each { |sink, level| sink.level = level }
  end

  def self.cleanup_receipts_by_title(title)
    TaskRequest.where(title: title).find_each do |receipt|
      event_id = receipt.external_event_id
      receipt.destroy!
      ExternalEvent.where(id: event_id).delete_all
    end
  end

  def self.cleanup_receipts_like(pattern)
    TaskRequest.where("title LIKE ?", pattern).find_each do |receipt|
      event_id = receipt.external_event_id
      receipt.destroy!
      ExternalEvent.where(id: event_id).delete_all
    end
  end
end
