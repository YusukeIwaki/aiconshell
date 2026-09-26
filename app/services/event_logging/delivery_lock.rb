# frozen_string_literal: true

module EventLogging
  # Serializes outbox delivery for as long as its PostgreSQL session lives.
  # Unlike a queue semaphore with a duration, this lock does not expire during
  # slow remote sends. Process exit closes the session and releases the lock.
  module DeliveryLock
    # Fixed bigint namespace ("AICONELD"), shared by every worker process.
    # Ruby String#hash is randomized between processes and must not be used.
    LOCK_KEY = 0x4149_434f_4e45_4c44

    class LockLost < StandardError; end

    # Returns the block value when acquired, or nil without yielding when busy.
    # Call outside any caller-owned transaction. One extra pooled connection is
    # reserved during the block; normal outbox queries use their own connection.
    # There is no transaction around the remote work, and no lock timeout/TTL.
    def self.with_lock(pool: ActiveRecord::Base.connection_pool)
      raise ArgumentError, "a delivery block is required" unless block_given?

      connection = pool.checkout
      acquired = nil
      begin
        if connection.transaction_open?
          raise ArgumentError, "delivery lock requires a connection without an open transaction"
        end

        # exec_query bypasses the query cache: acquisition is a side effect,
        # and a cached true result would allow an unprotected delivery.
        acquired = connection.exec_query(
          "SELECT pg_try_advisory_lock(#{LOCK_KEY})", "EventLog delivery lock"
        ).rows.dig(0, 0)
        unless acquired == true || acquired == false
          raise LockLost, "could not confirm EventLog delivery lock acquisition"
        end

        yield if acquired
      ensure
        release(pool, connection, acquired, $!)
      end
    end

    def self.release(pool, connection, acquired, original_error)
      reusable = acquired == false
      unlock_error = nil
      begin
        if acquired == true
          reusable = connection.exec_query(
            "SELECT pg_advisory_unlock(#{LOCK_KEY})", "EventLog delivery unlock"
          ).rows.dig(0, 0) == true
          unlock_error = LockLost.new("EventLog delivery lock session was lost") unless reusable
        end
      rescue StandardError => error
        unlock_error = error
      ensure
        if reusable
          pool.checkin(connection)
        else
          # An uncertain acquisition/unlock must never put a possibly locked
          # session back in the pool. Removing it also prevents reuse if closing
          # a failed socket raises; PostgreSQL releases locks on session exit.
          begin
            pool.remove(connection)
          ensure
            connection.disconnect!
          end
        end
      end
      raise unlock_error if unlock_error && original_error.nil?
    end
    private_class_method :release
  end
end
