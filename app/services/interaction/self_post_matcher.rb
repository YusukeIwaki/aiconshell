# frozen_string_literal: true

module Interaction
  # Persistent self-post matching for delegated OAuth plugins (issue #26).
  #
  # App-sent writes are matched by their durable receipt (provider
  # resource + external message/comment/issue id + actually sent content),
  # never by actor id. The consenting user's manual posts stay eligible:
  # a different id, a different resource, or edited content is not a
  # self-post. Same numeric ids on different resources never suppress.
  #
  # Receipts are the sent OutboundActions themselves: plugin, operation,
  # input (with the actually sent body persisted on `sent`), external_id,
  # and the fixed oauth_binding snapshot. In-flight (pending/sending) and
  # unknown (uncertain) actions hold matching poll candidates instead of
  # suppressing or dropping them.
  module SelfPostMatcher
    module_function

    # True when a polled event is exactly the app's own sent write.
    def self_post?(event, action)
      return false unless event.is_a?(Hash) && action.respond_to?(:plugin)

      plugin = action.plugin.to_s
      return false unless event["plugin"].to_s == plugin

      case plugin
      when "jira_oauth" then jira_self_post?(event, action)
      when "teams_oauth" then teams_self_post?(event, action)
      else false
      end
    end

    # True when an in-flight/uncertain action covers a poll candidate, so
    # the candidate must be held (not ingested as new work and not skipped
    # via cursor advance). Only already-started writes (`sending` with
    # `request_started_at` set, or `uncertain`) hold across generations in
    # the same provider resource space: the unknown external side effect
    # survives reconnect, so the matching echo stays held until reconciled.
    # `pending` never holds another generation, even when a rate-limited
    # attempt left `request_started_at` set: an explicit rejection carries
    # no unknown side effect, so cross-generation scope falls back to the
    # generation-pinned send permission (an old pending never holds a
    # reconnected poll). `sending` before `request_started_at` likewise
    # holds only its own generation. Different clouds/tenants/destinations
    # never hold.
    def hold_candidate?(event, action, poll_binding: nil)
      return false unless event.is_a?(Hash) && action.respond_to?(:plugin)
      return false unless event["plugin"].to_s == action.plugin.to_s
      return false unless %w[pending sending uncertain].include?(action.status.to_s)

      started = action.status.to_s == "uncertain" ||
        (action.status.to_s == "sending" && action.respond_to?(:request_started_at) &&
          !action.request_started_at.nil?)
      if started
        return false unless receipt_scope_matches?(action, poll_binding)
      else
        return false unless binding_matches?(action, poll_binding)
      end

      hold_keys_match?(hold_key_for_event(event), hold_key_for_action(action), event)
    end

    # Generation-pinned connection match for send permission and
    # in-flight holds: connection id, generation, provider, principal,
    # and tenant/cloud must all agree. A disconnect/replacement fails
    # closed instead of sending or holding as another principal.
    def binding_matches?(action, poll_binding)
      return true if poll_binding.nil? && action.oauth_binding.nil?
      return false if poll_binding.nil? || action.oauth_binding.nil?

      stored = action.oauth_binding.is_a?(Hash) ? action.oauth_binding : {}
      poll = poll_binding.is_a?(Hash) ? poll_binding : {}
      get = ->(hash, key) { hash[key.to_s].nil? ? hash[key.to_sym] : hash[key.to_s] }
      %w[connection_id generation provider principal tenant cloud].all? do |key|
        get.call(stored, key).to_s == get.call(poll, key).to_s &&
          !(key == "provider" && get.call(stored, key).to_s.empty?)
      end
    end

    # Generation-independent receipt scope: the same provider resource
    # space (provider plus the fixed tenant/cloud). Reconnecting (new
    # generation, connection id, or even principal) never changes it, so
    # a pre-reconnect app post re-fetched after a cursor reset is still
    # recognized as the same external echo. A different cloud, tenant,
    # or unknown scope never matches, so same numeric ids on other
    # resources are never suppressed. Receipt identity (resource plus
    # external id plus actually sent content) is checked separately by
    # self_post?; this is only the scope gate in front of it.
    def receipt_scope_matches?(action, poll_binding)
      return false if action.nil? || poll_binding.nil?
      return false unless action.respond_to?(:oauth_binding)

      stored = action.oauth_binding.is_a?(Hash) ? action.oauth_binding : {}
      poll = poll_binding.is_a?(Hash) ? poll_binding : {}
      get = ->(hash, key) { hash[key.to_s].nil? ? hash[key.to_sym] : hash[key.to_s] }
      provider = get.call(poll, "provider").to_s
      return false if provider.empty?
      return false unless get.call(stored, "provider").to_s == provider

      %w[tenant cloud].all? do |key|
        normalize_scope(get.call(stored, key)) == normalize_scope(get.call(poll, key))
      end
    end

    # -- Jira ----------------------------------------------------------

    def jira_self_post?(event, action)
      receipt_body = action.input.is_a?(Hash) ? (action.input["body"] || action.input[:body]).to_s : ""
      external_id = action.external_id.to_s
      return false if external_id.empty?

      case action.operation.to_s
      when "reply"
        receipt_resource = action.input.is_a?(Hash) ? (action.input["resource_id"] || action.input[:resource_id]).to_s : ""
        return false if receipt_resource.empty?
        return false unless event["resource_id"].to_s == receipt_resource

        comment_id = event.dig("payload", "comment_id").to_s
        event_id = event["event_id"].to_s
        matches_id = comment_id == external_id || event_id == "jira:comment:#{external_id}"
        return false unless matches_id

        # Edited content is a new human revision, not the app echo.
        event_text = event.dig("payload", "text").to_s
        event_text == receipt_body
      when "create_issue"
        return false unless event["resource_id"].to_s == "issue:#{external_id}"
        return false unless event.dig("payload", "key").to_s == external_id

        receipt_title = action.input.is_a?(Hash) ? (action.input["title"] || action.input[:title]).to_s : ""
        event_summary = event.dig("payload", "summary").to_s
        event_text = event.dig("payload", "text").to_s
        event_summary == receipt_title && event_text == receipt_body
      else
        false
      end
    end

    # -- Teams ---------------------------------------------------------

    def teams_self_post?(event, action)
      receipt_body = action.input.is_a?(Hash) ? (action.input["body"] || action.input[:body]).to_s : ""
      external_id = action.external_id.to_s
      return false if external_id.empty? || receipt_body.empty?

      event_resource = event["resource_id"].to_s
      event_content = event.dig("payload", "content").to_s
      return false unless event_content == receipt_body

      case action.operation.to_s
      when "send_message"
        # Channel root / chat message: receipt external_id is the event resource.
        event_resource == external_id
      when "reply"
        if external_id.start_with?("message:")
          # Channel thread reply: receipt is resource + "/" + reply id.
          receipt_resource = action.input.is_a?(Hash) ? (action.input["resource_id"] || action.input[:resource_id]).to_s : ""
          return false unless event_resource == receipt_resource

          reply_id = event.dig("payload", "message_id").to_s
          !reply_id.empty? && external_id == "#{receipt_resource}/#{reply_id}"
        else
          # Chat reply posts a new chat message: receipt is the event resource.
          event_resource == external_id
        end
      else
        false
      end
    end

    # -- hold keys (per-connection-plus-destination) -----------------------
    #
    # Jira holds are per issue, never per project: a pending reply to
    # issue:PROJ-1 must not hold poll candidates for issue:PROJ-2. A
    # pending create_issue (whose issue key is unknowable before the
    # write) holds its project instead. Teams holds stay at channel/chat
    # granularity. These keys are for hold scoping only; operator
    # allowlist checks keep using PluginAccess.destination.
    def hold_key_for_event(event)
      case event["plugin"].to_s
      when "jira_oauth"
        resource = event["resource_id"].to_s
        return resource if /\Aissue:[A-Za-z][A-Za-z0-9_]*-\d+\z/.match?(resource)

        nil
      when "teams_oauth"
        poll_destination_for(event)
      else
        nil
      end
    end

    def hold_key_for_action(action)
      case action.plugin.to_s
      when "jira_oauth"
        input = action.input.is_a?(Hash) ? action.input.transform_keys(&:to_s) : {}
        if action.operation.to_s == "reply"
          resource = input["resource_id"].to_s
          return resource if /\Aissue:[A-Za-z][A-Za-z0-9_]*-\d+\z/.match?(resource)

          nil
        else
          scope = input["scope"].to_s
          return "project:#{scope.upcase}" if /\A[A-Za-z][A-Za-z0-9_]*\z/.match?(scope)

          nil
        end
      when "teams_oauth"
        action_destination_for(action)
      else
        nil
      end
    end

    def hold_keys_match?(event_key, action_key, event)
      return false if event_key.nil? || action_key.nil?
      return true if event_key == action_key

      # A pending create_issue covers its whole project: any polled
      # issue event in that project is held with it.
      if action_key.start_with?("project:")
        match = /\Aissue:([A-Za-z][A-Za-z0-9_]*)-\d+\z/.match(event["resource_id"].to_s)
        return !match.nil? && "project:#{match[1].upcase}" == action_key
      end

      false
    end

    def normalize_scope(value)
      value.nil? ? nil : value.to_s
    end

    # -- destinations for hold scoping ---------------------------------

    def poll_destination_for(event)
      plugin = event["plugin"].to_s
      payload = event["payload"].is_a?(Hash) ? event["payload"] : {}
      case plugin
      when "jira_oauth"
        resource = event["resource_id"].to_s
        match = /\Aissue:([A-Za-z][A-Za-z0-9_]*)-\d+\z/.match(resource)
        match ? match[1].upcase : nil
      when "teams_oauth"
        resource = event["resource_id"].to_s
        channel = /\Amessage:([^\/]+)\/([^\/]+)\/[^\/]+\z/.match(resource)
        return "team/#{channel[1]}/channel/#{channel[2]}" if channel

        chat = /\Achat_message:([^\/]+)\/[^\/]+\z/.match(resource)
        return "chat/#{chat[1]}" if chat

        nil
      else
        nil
      end
    end

    def action_destination_for(action)
      input = action.input.is_a?(Hash) ? action.input.transform_keys(&:to_s) : {}
      PluginAccess.destination(action.plugin.to_s, action.operation.to_s, input)
    rescue StandardError
      nil
    end
  end
end
