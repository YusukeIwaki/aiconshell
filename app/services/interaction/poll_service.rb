# frozen_string_literal: true

require "securerandom"

module Interaction
  # Polls one plugin scope into the durable inbox.
  #
  # Guarantees:
  # - scope must be allowlisted in WorkflowSettings, never trusted from callers alone
  # - overlapping polls are skipped via a short cursor lease (row lock + token)
  # - bot/system events are persisted but marked processed so they start no loops
  # - the cursor advances only after every valid event of the poll is persisted
  # - failures are recorded on the cursor (visible) and stay retryable; config
  #   errors do not raise for endless Solid Queue retries
  class PollService
    Result = Struct.new(:ok, :code, :ingested, :skipped, :retryable, keyword_init: true)

    def initialize(registry: nil, event_sink: WorkflowEvents, clock: Time)
      @registry = registry || default_registry
      @event_sink = event_sink
      @clock = clock
    end

    def call(plugin:, scope:)
      now = current_time
      cursor = find_or_create_cursor(plugin, scope)

      unless WorkflowSettings.scope_allowed?(plugin, scope)
        record_cursor_error(cursor, "scope #{plugin}:#{scope} is not allowlisted", now)
        return Result.new(ok: false, code: :scope_not_allowed, ingested: 0, skipped: 0, retryable: false)
      end

      if @registry.nil?
        record_cursor_error(cursor, "plugin registry is not available", now)
        return Result.new(ok: false, code: :registry_missing, ingested: 0, skipped: 0, retryable: false)
      end

      leased = acquire_lease(cursor, now)
      return Result.new(ok: true, code: :lease_skipped, ingested: 0, skipped: 0, retryable: false) if leased.nil?

      lease_token, stored_cursor = leased
      response = invoke_latest_events(plugin, scope, stored_cursor)
      unless response[:ok]
        release_lease_with_error(cursor, lease_token, response[:error], now)
        return Result.new(ok: false, code: response[:code], ingested: 0, skipped: 0,
                          retryable: response[:retryable])
      end

      valid, invalid_count = normalize_events(response[:events], plugin)
      ingested = persist_events(valid, now)
      if invalid_count.positive?
        release_lease_with_error(cursor, lease_token,
                                 "#{invalid_count} event(s) failed validation and were skipped", now)
        @event_sink.emit(layer: "interaction", kind: "poll.invalid_events",
                         message: "Poll stored #{ingested}, skipped #{invalid_count} invalid",
                         data: { plugin: plugin, scope: scope, ingested: ingested, invalid: invalid_count })
        return Result.new(ok: false, code: :invalid_events, ingested: ingested, skipped: invalid_count,
                          retryable: true)
      end

      commit_cursor(cursor, lease_token, response[:cursor], now)
      @event_sink.emit(layer: "interaction", kind: "poll.completed",
                       message: "Poll ingested #{ingested} event(s)",
                       data: { plugin: plugin, scope: scope, ingested: ingested })
      Result.new(ok: true, code: :ok, ingested: ingested, skipped: 0, retryable: false)
    end

    private

    def default_registry
      return nil unless defined?(Aiconshell::Plugins::Registry)

      Aiconshell::Plugins::Registry.default
    rescue StandardError
      nil
    end

    def current_time
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end

    def find_or_create_cursor(plugin, scope)
      IntegrationCursor.find_or_create_by!(plugin: plugin.to_s, scope: scope.to_s)
    end

    # Returns [lease_token, stored_cursor] or nil when another poll holds the lease.
    # Holds the row lock only for the lease check-and-set, never across network I/O.
    def acquire_lease(cursor, now)
      token = SecureRandom.uuid
      stored = nil
      IntegrationCursor.transaction do
        cursor.with_lock do
          return nil if cursor.lease_active?(now)

          cursor.update!(lease_token: token, lease_expires_at: now + WorkflowSettings.poll_lease_seconds)
          stored = cursor.cursor
        end
      end
      [token, stored]
    end

    def invoke_latest_events(plugin, scope, stored_cursor)
      output = @registry.invoke(
        plugin: plugin.to_s, operation: "latest_events",
        input: { "scope" => scope.to_s, "cursor" => stored_cursor },
        context: { "scopes" => WorkflowSettings.allowed_scopes }
      )
      events = output["events"] || output[:events] || []
      cursor = output["cursor"] || output[:cursor]
      { ok: true, events: Array(events), cursor: cursor }
    rescue StandardError => e
      { ok: false, error: "#{e.class}: #{safe_message(e)}", code: :plugin_error, retryable: retryable?(e) }
    end

    # Non-retryable: unknown/unsupported/config errors must not cause retry storms.
    def retryable?(error)
      name = error.class.name.to_s
      return false if name.match?(/Unknown|Unsupported|NotFound|Invalid|NotConfigured|NotAllowed|Permission/i)
      return false if error.message.to_s.match?(/allowlist|not configured|unknown|unsupported/i)

      true
    end

    def normalize_events(events, plugin)
      valid = []
      invalid = 0
      events.each do |event|
        row = normalize_event(event, plugin)
        row ? valid << row : invalid += 1
      end
      [valid, invalid]
    end

    def normalize_event(event, plugin)
      return nil unless event.is_a?(Hash)

      e = event.transform_keys(&:to_s)
      event_id = e["event_id"].to_s
      fingerprint = e["fingerprint"].to_s
      resource_id = e["resource_id"].to_s
      actor_type = e["actor_type"].to_s
      occurred_at = parse_time(e["occurred_at"])
      payload = e["payload"]
      return nil if event_id.empty? || fingerprint.empty? || resource_id.empty?
      return nil unless ExternalEvent::ACTOR_TYPES.include?(actor_type)
      return nil if occurred_at.nil? || !payload.is_a?(Hash)

      {
        "plugin" => plugin.to_s,
        "event_id" => event_id,
        "fingerprint" => fingerprint,
        "event_type" => e["event_type"].to_s.presence || "message",
        "resource_id" => resource_id,
        "actor_id" => e["actor_id"].to_s,
        "actor_type" => actor_type,
        "occurred_at" => occurred_at,
        "payload" => payload
      }
    end

    def parse_time(value)
      return nil if value.nil?
      return value if value.is_a?(Time) || value.is_a?(DateTime)

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # Idempotent bulk insert; bot/system rows land pre-processed so triage
    # never turns self-events into new work.
    def persist_events(rows, now)
      return 0 if rows.empty?

      stamped = rows.map do |row|
        bot = row["actor_type"] != "human"
        row.merge(
          "processed_at" => (bot ? now : nil),
          "created_at" => now, "updated_at" => now
        )
      end
      ExternalEvent.insert_all(
        stamped,
        unique_by: :index_external_events_on_plugin_event_fingerprint,
        record_timestamps: false
      )
      stamped.size
    end

    def commit_cursor(cursor, lease_token, new_cursor, now)
      IntegrationCursor.transaction do
        cursor.with_lock do
          return false unless cursor.lease_token == lease_token

          cursor.update!(cursor: new_cursor, last_polled_at: now, lease_token: nil,
                         lease_expires_at: nil, last_error: nil, consecutive_failures: 0)
          true
        end
      end
    end

    def release_lease_with_error(cursor, lease_token, error, now)
      IntegrationCursor.transaction do
        cursor.with_lock do
          next unless cursor.lease_token == lease_token

          cursor.update!(lease_token: nil, lease_expires_at: nil, last_error: error.to_s[0, 2000],
                         consecutive_failures: cursor.consecutive_failures.to_i + 1)
        end
      end
      @event_sink.emit(layer: "interaction", kind: "poll.failed", message: "Poll failed",
                       data: { plugin: cursor.plugin, scope: cursor.scope })
    end

    def record_cursor_error(cursor, error, now)
      IntegrationCursor.transaction do
        cursor.with_lock do
          cursor.update!(last_error: error.to_s[0, 2000],
                         consecutive_failures: cursor.consecutive_failures.to_i + 1)
        end
      end
      @event_sink.emit(layer: "interaction", kind: "poll.failed", message: "Poll rejected",
                       data: { plugin: cursor.plugin, scope: cursor.scope })
    end

    def safe_message(error)
      error.message.to_s[0, 500]
    end
  end
end
