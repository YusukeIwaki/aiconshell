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

    # True when an in-flight/uncertain action covers the same connection
    # and destination as a poll candidate, so the candidate must be held
    # (not ingested as new work and not skipped via cursor advance).
    def hold_candidate?(event, action, poll_binding: nil)
      return false unless event.is_a?(Hash) && action.respond_to?(:plugin)
      return false unless event["plugin"].to_s == action.plugin.to_s
      return false unless %w[pending sending uncertain].include?(action.status.to_s)
      return false unless binding_matches?(action, poll_binding)

      poll_destination = poll_destination_for(event)
      action_destination = action_destination_for(action)
      return false if poll_destination.nil? || action_destination.nil?

      poll_destination == action_destination
    end

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
