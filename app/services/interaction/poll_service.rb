# frozen_string_literal: true

require "securerandom"
require "digest"
require "json"

module Interaction
  # Network calls run outside transactions. A current cursor lease fences the
  # final atomic inbox insert + cursor acknowledgement; stale polls write neither.
  class PollService
    Result = Struct.new(:ok, :code, :ingested, :skipped, :retryable, keyword_init: true)
    SNAPSHOT_TYPES = %w[github.issue jira.issue teams.message teams.reply discord.message].freeze

    def initialize(registry: Aiconshell::Plugins::Registry.default, event_sink: WorkflowEvents, clock: Time)
      @registry, @event_sink, @clock = registry, event_sink, clock
    end

    def call(plugin:, scope:)
      cursor = IntegrationCursor.find_or_create_by!(plugin: plugin.to_s, scope: scope.to_s)
      unless WorkflowSettings.scope_allowed?(plugin, scope)
        record_error(cursor, "scope is not allowlisted")
        return result(false, :scope_not_allowed)
      end
      token = SecureRandom.uuid
      stored_cursor = nil
      leased = cursor.with_lock do
        next false if cursor.lease_active?(now)

        cursor.update!(lease_token: token, lease_expires_at: now + WorkflowSettings.poll_lease_seconds)
        stored_cursor = cursor.cursor
        true
      end
      return result(true, :lease_skipped) unless leased

      response = @registry.invoke(plugin: plugin.to_s, operation: "latest_events",
        input: { "scope" => scope.to_s, "cursor" => stored_cursor },
        context: PluginAccess.context(plugin, "latest_events", registry: @registry))
      unless response.is_a?(Hash) && response["events"].is_a?(Array) && response["cursor"].is_a?(Hash)
        raise ArgumentError, "invalid plugin response"
      end
      rows = response["events"].filter_map { |event| normalize(event, plugin, scope) }
      invalid = response["events"].size - rows.size
      outcome = cursor.with_lock(requires_new: true) do
        next result(false, :stale_poll, retryable: true) unless cursor.lease_token == token && cursor.lease_active?(now)

        inserted = persist_events(rows)
        # Source locks (including a concurrent triage row lock) may outlive
        # the lease. Roll back every event/watermark write before acknowledging.
        raise ActiveRecord::Rollback unless cursor.lease_active?(now)

        attrs = { lease_token: nil, lease_expires_at: nil }
        if invalid.positive?
          attrs.merge!(last_error: "#{invalid} invalid events; cursor retained",
            consecutive_failures: cursor.consecutive_failures + 1)
        else
          attrs.merge!(cursor: response["cursor"], last_polled_at: now,
            last_error: nil, consecutive_failures: 0)
        end
        cursor.update!(attrs)
        result(invalid.zero?, invalid.zero? ? :ok : :invalid_events,
          ingested: inserted, skipped: invalid, retryable: invalid.positive?)
      end || result(false, :stale_poll, retryable: true)
      @event_sink.emit(layer: "interaction", kind: outcome.ok ? "poll.completed" : "poll.failed",
        message: "Poll #{outcome.code}", data: { plugin: plugin, ingested: outcome.ingested })
      outcome
    rescue StandardError => error
      record_error(cursor, "Polling failed (#{error.class.name})", token: token) if cursor
      result(false, :plugin_error, retryable: retryable?(error))
    end

    private

    def now = @clock.respond_to?(:current) ? @clock.current : @clock.now

    def result(ok, code, ingested: 0, skipped: 0, retryable: false)
      Result.new(ok: ok, code: code, ingested: ingested, skipped: skipped, retryable: retryable)
    end

    def normalize(event, plugin, scope)
      return unless event.is_a?(Hash)

      row = event.transform_keys(&:to_s)
      return unless %w[event_id fingerprint event_type resource_id actor_id].all? { |key| row[key].is_a?(String) && row[key].present? }
      return unless ExternalEvent::ACTOR_TYPES.include?(row["actor_type"]) && row["payload"].is_a?(Hash)

      occurred_at = Time.iso8601(row["occurred_at"].to_s).floor(6)
      ignored = row["actor_type"] == "bot" || PluginAccess.self_actor_ids(plugin).include?(row["actor_id"])
      row.slice("event_id", "fingerprint", "event_type", "resource_id", "actor_id", "actor_type").merge(
        "plugin" => plugin.to_s, "occurred_at" => occurred_at,
        "payload" => row["payload"].merge("integration_scope" => scope.to_s),
        "processed_at" => ignored ? now : nil, "created_at" => now, "updated_at" => now)
    rescue ArgumentError
      nil
    end

    def persist_events(rows)
      snapshots, events = rows.partition { |row| SNAPSHOT_TYPES.include?(row["event_type"]) }
      # A source can appear through multiple cursors. Serialize its first insert
      # as well as later revisions. Stable lock order avoids cross-batch deadlocks.
      sources = snapshots.group_by { |row| row.values_at("plugin", "event_id") }.sort
      sources.each do |identity, _|
        key = Digest::SHA256.digest(JSON.generate(["poll-snapshot", *identity])).unpack1("q>")
        ExternalEvent.connection.execute("SELECT pg_advisory_xact_lock(#{key})")
      end

      inserted = events.empty? ? 0 : ExternalEvent.insert_all(events,
        unique_by: :index_external_events_on_plugin_event_fingerprint, returning: %w[id]).rows.size
      sources.each do |(plugin, event_id), revisions|
        previous = ExternalEvent.where(plugin: plugin, event_id: event_id, event_type: SNAPSHOT_TYPES)
          .order(occurred_at: :desc, id: :desc).lock.first
        # Adapters/pages need not return chronological order. Preserve the input
        # order for timestamp ties; conflicting tied snapshots are first-wins.
        revisions.each_with_index.sort_by { |row, index| [row["occurred_at"], index] }.each do |row, _|
          source_fingerprint = row.fetch("fingerprint")
          if previous
            watermark = previous.source_updated_at || previous.occurred_at
            next if row["occurred_at"] <= watermark

            if source_fingerprint == (previous.source_fingerprint || previous.fingerprint)
              # Metadata-only updates still advance the source watermark, so
              # a delayed older content change cannot masquerade as a new edit.
              previous.update_columns(source_updated_at: row["occurred_at"])
              next
            end
          end

          fingerprint = "revision:#{Digest::SHA256.hexdigest(JSON.generate([
            plugin, event_id, previous&.fingerprint, source_fingerprint
          ]))}"
          previous = ExternalEvent.create!(row.merge("fingerprint" => fingerprint,
            "source_fingerprint" => source_fingerprint, "source_updated_at" => row["occurred_at"]))
          inserted += 1
        end
      end
      inserted
    end

    def record_error(cursor, message, token: nil)
      cursor.with_lock do
        next if token && cursor.lease_token != token

        attrs = { last_error: message, consecutive_failures: cursor.consecutive_failures + 1 }
        attrs.merge!(lease_token: nil, lease_expires_at: nil) if token
        cursor.update!(attrs)
      end
      @event_sink.emit(layer: "interaction", kind: "poll.failed", message: message,
        data: { plugin: cursor.plugin })
    rescue StandardError
      Rails.logger.warn("Poll failure could not be recorded")
    end

    def retryable?(error)
      !error.class.name.match?(/Unknown|Unsupported|Invalid|NotConfigured|CredentialsMissing|Permission|HostRejected/)
    end
  end
end
