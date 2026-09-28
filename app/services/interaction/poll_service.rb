# frozen_string_literal: true

require "securerandom"
require "digest"
require "json"

module Interaction
  # Network calls run outside transactions. A current cursor lease fences the
  # final atomic inbox insert + cursor acknowledgement; stale polls write neither.
  #
  # Delegated OAuth plugins (issue #26) poll with a trusted binding snapshot
  # fixed before HTTP and fenced after it: a disconnect/replacement between
  # snapshot and commit discards the result instead of advancing another
  # connection's cursor. Cursors are isolated per connection via the stored
  # oauth_binding; a changed connection restarts from no cursor. Self-posts
  # are suppressed only by durable sent receipts (never by actor id), and
  # in-flight/uncertain sends hold matching candidates without advancing
  # the cursor. Already-started HTTP cannot be cancelled; ambiguous writes
  # stay `uncertain` and are never auto-resent (see OutboundService).
  class PollService
    Result = Struct.new(:ok, :code, :ingested, :skipped, :retryable, keyword_init: true)
    SNAPSHOT_TYPES = %w[github.issue jira.issue teams.message teams.reply discord.message].freeze
    # Delegated Teams polls emit namespaced types analogous to the legacy
    # snapshots. JiraOauth reuses the legacy `jira.*` types (with
    # plugin=jira_oauth for isolation), so no extra jira entries belong here:
    # legacy `jira.comment` / `jira.change` stay non-snapshot globally.
    OAUTH_SNAPSHOT_TYPES = %w[teams_oauth.message teams_oauth.reply teams_oauth.chat_message].freeze

    def initialize(registry: Aiconshell::Plugins::Registry.default, event_sink: WorkflowEvents, clock: Time,
                   oauth_credential_provider: nil)
      @registry, @event_sink, @clock = registry, event_sink, clock
      @oauth_credential_provider = oauth_credential_provider
    end

    def call(plugin:, scope:)
      plugin_name = plugin.to_s
      scope_name = scope.to_s
      cursor = IntegrationCursor.find_or_create_by!(plugin: plugin_name, scope: scope_name)
      unless WorkflowSettings.scope_allowed?(plugin_name, scope_name)
        record_error(cursor, "scope is not allowlisted")
        return result(false, :scope_not_allowed)
      end

      oauth_snapshot = nil
      if OauthContext.oauth_plugin?(plugin_name)
        begin
          oauth_snapshot = OauthContext.snapshot_binding(plugin_name, credential_provider: oauth_provider)
        rescue Oauth::CredentialProvider::NotConnected => error
          record_error(cursor, "OAuth #{error.code}")
          return result(false, :not_connected)
        rescue Aiconshell::Oauth::Error => error
          record_error(cursor, "OAuth #{error.code}")
          return result(false, :not_connected)
        end
      end

      token = SecureRandom.uuid
      stored_cursor = nil
      stored_binding = nil
      leased = cursor.with_lock do
        next false if cursor.lease_active?(now)

        cursor.update!(lease_token: token, lease_expires_at: now + WorkflowSettings.poll_lease_seconds)
        stored_cursor = cursor.cursor
        stored_binding = cursor.respond_to?(:oauth_binding) ? cursor.oauth_binding : nil
        true
      end
      return result(true, :lease_skipped) unless leased

      # Cursor isolation per connection: a replaced/disconnected connection
      # never reuses another site's cursor. A changed binding restarts from
      # no cursor; the new binding is stored only on successful commit.
      effective_cursor = stored_cursor
      if OauthContext.oauth_plugin?(plugin_name) && !binding_equal?(stored_binding, oauth_snapshot)
        effective_cursor = nil unless stored_binding.nil? && oauth_snapshot.nil?
        effective_cursor = nil if oauth_snapshot && !stored_binding.nil?
      end

      context = if OauthContext.oauth_plugin?(plugin_name)
        PluginAccess.context(plugin_name, "latest_events", registry: @registry).merge(
          "oauth_binding" => oauth_snapshot, "oauth_credential_provider" => oauth_provider
        )
      else
        PluginAccess.context(plugin_name, "latest_events", registry: @registry)
      end

      response = @registry.invoke(plugin: plugin_name, operation: "latest_events",
        input: { "scope" => scope_name, "cursor" => effective_cursor },
        context: context)
      unless response.is_a?(Hash) && response["events"].is_a?(Array) && response["cursor"].is_a?(Hash)
        raise ArgumentError, "invalid plugin response"
      end

      # Fencing: a disconnect/replacement during HTTP discards the result.
      # The old result never revives the connection, sends as a new user,
      # or advances another connection's cursor.
      if OauthContext.oauth_plugin?(plugin_name) &&
          !OauthContext.snapshot_current?(oauth_snapshot, plugin_name, credential_provider: oauth_provider)
        # A stale poll releases only its own lease token: a successor poll
        # may already hold the cursor, and its lease must never be cleared
        # here. Update failures propagate to the outer rescue, which
        # records the error without advancing the cursor.
        cursor.with_lock do
          if cursor.lease_token == token
            cursor.update!(lease_token: nil, lease_expires_at: nil)
          end
        end
        return result(false, :stale_binding, retryable: true)
      end

      rows = response["events"].filter_map { |event| normalize(event, plugin_name, scope_name) }
      invalid = response["events"].size - rows.size

      if OauthContext.oauth_plugin?(plugin_name)
        held_rows, pass_rows = partition_held(rows, plugin_name, oauth_snapshot)
        if held_rows.any?
          # Mixed batches ingest unrelated candidates while retaining held
          # ones: persist the pass set but never advance the cursor past
          # held candidates (they are re-fetched via overlap until the
          # send settles). DB/matcher errors above propagate and halt
          # everything instead of treating the batch as ordinary events.
          pass_rows = suppress_self_posts(pass_rows, plugin_name, oauth_snapshot)
          outcome = cursor.with_lock(requires_new: true) do
            next result(false, :stale_poll, retryable: true) unless cursor.lease_token == token && cursor.lease_active?(now)

            if !OauthContext.snapshot_current?(oauth_snapshot, plugin_name, credential_provider: oauth_provider)
              cursor.update!(lease_token: nil, lease_expires_at: nil)
              next result(false, :stale_binding, retryable: true)
            end
            if OauthContext.oauth_plugin?(plugin_name)
              current_stored = cursor.respond_to?(:oauth_binding) ? cursor.oauth_binding : nil
              unless binding_equal?(current_stored, stored_binding)
                cursor.update!(lease_token: nil, lease_expires_at: nil)
                next result(false, :stale_binding, retryable: true)
              end
            end

            inserted = persist_events(pass_rows, plugin_name, oauth_snapshot)
            raise ActiveRecord::Rollback unless cursor.lease_active?(now)

            cursor.update!(lease_token: nil, lease_expires_at: nil,
              last_error: "held for in-flight delivery; cursor retained",
              consecutive_failures: cursor.consecutive_failures + 1)
            result(false, :held, ingested: inserted, skipped: invalid, retryable: true)
          end || result(false, :stale_poll, retryable: true)
          @event_sink.emit(layer: "interaction", kind: "poll.failed",
            message: "Poll held", data: { plugin: plugin_name, ingested: outcome.ingested })
          emit_hold(plugin_name)
          return outcome
        end
        rows = suppress_self_posts(rows, plugin_name, oauth_snapshot)
      end

      outcome = cursor.with_lock(requires_new: true) do
        next result(false, :stale_poll, retryable: true) unless cursor.lease_token == token && cursor.lease_active?(now)

        # Re-fence under the cursor lock: a replacement that landed while
        # waiting for the lock still discards instead of committing.
        if OauthContext.oauth_plugin?(plugin_name) &&
            !OauthContext.snapshot_current?(oauth_snapshot, plugin_name, credential_provider: oauth_provider)
          cursor.update!(lease_token: nil, lease_expires_at: nil)
          next result(false, :stale_binding, retryable: true)
        end
        # A stored binding that changed under us also discards: another
        # poll already fenced this generation.
        if OauthContext.oauth_plugin?(plugin_name)
          current_stored = cursor.respond_to?(:oauth_binding) ? cursor.oauth_binding : nil
          unless binding_equal?(current_stored, stored_binding)
            cursor.update!(lease_token: nil, lease_expires_at: nil)
            next result(false, :stale_binding, retryable: true)
          end
        end

        inserted = persist_events(rows, plugin_name, oauth_snapshot)
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
          attrs[:oauth_binding] = oauth_snapshot if OauthContext.oauth_plugin?(plugin_name) && cursor.respond_to?(:oauth_binding)
        end
        cursor.update!(attrs)
        result(invalid.zero?, invalid.zero? ? :ok : :invalid_events,
          ingested: inserted, skipped: invalid, retryable: invalid.positive?)
      end || result(false, :stale_poll, retryable: true)
      @event_sink.emit(layer: "interaction", kind: outcome.ok ? "poll.completed" : "poll.failed",
        message: "Poll #{outcome.code}", data: { plugin: plugin_name, ingested: outcome.ingested })
      outcome
    rescue StandardError => error
      record_error(cursor, "Polling failed (#{error.class.name})", token: token) if cursor
      result(false, :plugin_error, retryable: retryable?(error))
    end

    private

    def now = @clock.respond_to?(:current) ? @clock.current : @clock.now

    def oauth_provider
      @oauth_credential_provider ||= Oauth::CredentialProvider.new(event_sink: @event_sink)
    end

    def result(ok, code, ingested: 0, skipped: 0, retryable: false)
      Result.new(ok: ok, code: code, ingested: ingested, skipped: skipped, retryable: retryable)
    end

    def binding_equal?(left, right)
      normalize_binding(left) == normalize_binding(right)
    end

    def normalize_binding(binding)
      return nil if binding.nil?

      hash = binding.is_a?(Hash) ? binding : {}
      %w[connection_id generation provider principal tenant cloud].to_h do |key|
        value = hash[key.to_s].nil? ? hash[key.to_sym] : hash[key.to_s]
        [key, value.to_s]
      end
    end

    def normalize(event, plugin, scope)
      return unless event.is_a?(Hash)

      row = event.transform_keys(&:to_s)
      return unless %w[event_id fingerprint event_type resource_id actor_id].all? { |key| row[key].is_a?(String) && row[key].present? }
      return unless ExternalEvent::ACTOR_TYPES.include?(row["actor_type"]) && row["payload"].is_a?(Hash)

      occurred_at = Time.iso8601(row["occurred_at"].to_s).floor(6)
      ignored = if OauthContext.oauth_plugin?(plugin)
        # Delegated plugins never suppress by actor: the consenting user's
        # manual posts stay eligible; only durable receipts suppress.
        row["actor_type"] == "bot"
      else
        row["actor_type"] == "bot" || PluginAccess.self_actor_ids(plugin).include?(row["actor_id"])
      end
      row.slice("event_id", "fingerprint", "event_type", "resource_id", "actor_id", "actor_type").merge(
        "plugin" => plugin.to_s, "occurred_at" => occurred_at,
        "payload" => row["payload"].merge("integration_scope" => scope.to_s),
        "processed_at" => ignored ? now : nil, "created_at" => now, "updated_at" => now)
    rescue ArgumentError
      nil
    end

    # Partitions candidates into held vs ingestible. Held rows overlap a
    # pending/sending/uncertain action for their destination (see
    # SelfPostMatcher.hold_candidate? for pending vs started scoping).
    # DB or matcher errors propagate (never coerce to false): the outer
    # rescue then halts ingestion and the cursor advance instead of
    # treating the batch as ordinary human events.
    def partition_held(rows, plugin, snapshot)
      return [[], rows] if rows.empty?

      actions = OutboundAction.where(plugin: plugin, status: %w[pending sending uncertain]).to_a
      return [[], rows] if actions.empty?

      rows.partition do |row|
        actions.any? { |action| SelfPostMatcher.hold_candidate?(row, action, poll_binding: snapshot) }
      end
    end

    def hold_for_inflight?(rows, plugin, snapshot)
      held, _pass = partition_held(rows, plugin, snapshot)
      held.any?
    end

    # Suppresses only durable self-post echoes. Receipts are scoped in
    # the database to this plugin, confirmed sends, and the same
    # provider resource space (provider plus tenant/cloud, never the
    # numeric id alone), newest first, with no row cap: a confirmed
    # self-post at position 501+ still matches no matter how many older
    # receipts other destinations or past connections left behind.
    # Generation is deliberately not part of the scope, so a
    # pre-reconnect post re-fetched after a cursor reset is still
    # recognized; send permission itself stays generation-pinned
    # elsewhere. DB errors propagate and halt the poll (see above).
    def suppress_self_posts(rows, plugin, snapshot)
      receipts = sent_receipts_for(plugin, snapshot)
      return rows if receipts.empty?

      rows.reject do |row|
        receipts.any? { |action| SelfPostMatcher.self_post?(row, action) }
      end
    end

    def sent_receipts_for(plugin, snapshot)
      query = OutboundAction.where(plugin: plugin.to_s, status: "sent").where.not(external_id: nil)
      query = scope_receipts_to_provider_space(query, snapshot)
      return [] if query.nil?

      query.order(id: :desc).to_a.select do |action|
        SelfPostMatcher.receipt_scope_matches?(action, snapshot)
      end
    end

    # Narrows the receipt lookup to the same provider resource space
    # before Ruby matching. Returns nil when the poll binding is
    # missing: with no trusted scope, nothing is suppressed (fail open
    # toward human review instead of hiding posts behind an unknown
    # scope).
    def scope_receipts_to_provider_space(query, snapshot)
      return nil unless snapshot.is_a?(Hash)

      get = ->(key) do
        value = snapshot[key.to_s]
        value.nil? ? snapshot[key.to_sym] : value
      end
      provider = get.call("provider").to_s
      return nil if provider.empty?

      query = query.where("oauth_binding ->> 'provider' = ?", provider)
      query = query.where("oauth_binding ->> 'tenant' IS NOT DISTINCT FROM ?", get.call("tenant")&.to_s)
      query = query.where("oauth_binding ->> 'cloud' IS NOT DISTINCT FROM ?", get.call("cloud")&.to_s)
      query
    end

    def emit_hold(plugin)
      @event_sink.emit(layer: "interaction", kind: "poll.held", message: "Poll held for in-flight delivery",
        data: { plugin: plugin })
    rescue StandardError
      nil
    end

    # Every persisted row keeps the trusted binding that fetched it, so
    # triage can fence the later Task reply against the fetch-time
    # connection instead of the current one. Raw provider IDs stay
    # unchanged. External identity scopes by provider resource space
    # (`oauth_event_space`: provider plus tenant/cloud, never the
    # fetching generation): the same object revision re-fetched after a
    # reconnect dedups to the already-handled row instead of creating new
    # work, while the same numeric IDs on a different cloud/tenant stay
    # distinct rows with distinct watermarks. The generation-scoped Task
    # join key (`oauth_source_key`) is stamped alongside so triage pins
    # genuinely new posts/edits to their fetching generation; legacy rows
    # keep global dedup with NULL keys.
    def persist_events(rows, plugin = nil, snapshot = nil)
      stamp_binding!(rows, plugin, snapshot)
      snapshots, events = rows.partition { |row| snapshot_row?(row) }
      # A source can appear through multiple cursors. Serialize its first insert
      # as well as later revisions. Stable lock order avoids cross-batch deadlocks.
      sources = snapshots.group_by { |row| row.values_at("plugin", "oauth_event_space", "event_id") }.sort
      sources.each do |identity, _|
        key = Digest::SHA256.digest(JSON.generate(["poll-snapshot", *identity])).unpack1("q>")
        ExternalEvent.connection.execute("SELECT pg_advisory_xact_lock(#{key})")
      end

      unique_by = if OauthContext.oauth_plugin?(plugin.to_s)
        :index_external_events_oauth_dedup
      else
        :index_external_events_legacy_dedup
      end
      inserted = events.empty? ? 0 : ExternalEvent.insert_all(events,
        unique_by: unique_by, returning: %w[id]).rows.size
      sources.each do |(plugin, event_space, event_id), revisions|
        previous = ExternalEvent.where(plugin: plugin, event_id: event_id, event_type: snapshot_event_types)
        previous = previous.where(oauth_event_space: event_space)
        previous = previous.order(occurred_at: :desc, id: :desc).lock.first
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

    def stamp_binding!(rows, plugin, snapshot)
      return if rows.empty?
      return unless OauthContext.oauth_plugin?(plugin.to_s) && snapshot.is_a?(Hash)
      return unless ExternalEvent.column_names.include?("oauth_binding")

      key = OauthContext.source_key_for(plugin.to_s, snapshot)
      space = OauthContext.event_space_key_for(plugin.to_s, snapshot)
      rows.each do |row|
        row["oauth_binding"] = snapshot
        row["oauth_source_key"] = key if ExternalEvent.column_names.include?("oauth_source_key")
        row["oauth_event_space"] = space if ExternalEvent.column_names.include?("oauth_event_space")
      end
    end

    def snapshot_row?(row)
      (SNAPSHOT_TYPES + OAUTH_SNAPSHOT_TYPES).include?(row["event_type"])
    end

    def snapshot_event_types
      SNAPSHOT_TYPES + OAUTH_SNAPSHOT_TYPES
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
