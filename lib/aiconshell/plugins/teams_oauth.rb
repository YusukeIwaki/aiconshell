# frozen_string_literal: true

require "date"
require "json"
require "time"
require "uri"
require_relative "../oauth/errors" unless defined?(Aiconshell::Oauth::BindingMismatch)

module Aiconshell
  module Plugins
    # Microsoft Teams adapter acting as the OAuth-consented user.
    #
    # Unlike `teams` (Graph application + Bot Connector with service-account
    # credentials), this adapter performs only delegated Graph calls with a
    # user access token resolved just-in-time from the trusted context
    # (`oauth_binding` + `oauth_credential_provider`). It never reads
    # `TEAMS_*` application/Bot credentials and never falls back to them.
    #
    # Poll scope: "team/<teamId>/channel/<channelId>" or "chat/<chatId>".
    # latest_events cursor: {"since": ISO8601}. All channel roots and their
    # replies (or all chat pages) are traversed before advancing it.
    # Write scope: "channel:<teamId>/<channelId>" or "chat:<chatId>".
    # Reply resource: "message:<teamId>/<channelId>/<rootId>" (channel
    # thread reply) or "chat_message:<chatId>/<messageId>" (posts a new
    # message to the same chat; chats have no thread-reply endpoint).
    # create_issue is explicitly unsupported: Teams has no issue tracker.
    class TeamsOauth < Base
      plugin_id "teams_oauth"
      required_env "OAUTH_MICROSOFT_CLIENT_ID", "OAUTH_MICROSOFT_CLIENT_SECRET",
                   "OAUTH_MICROSOFT_CLIENT_SECRET_FILE", "OAUTH_MICROSOFT_TENANT_ID",
                   "OAUTH_MICROSOFT_REDIRECT_URI"

      operation "latest_events",
                input_schema: Schemas::LATEST_EVENTS_INPUT,
                output_schema: Schemas::LATEST_EVENTS_OUTPUT,
                scope: "teams_oauth:read",
                read_only: true
      operation "reply",
                input_schema: Schemas::REPLY_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "teams_oauth:write"
      operation "send_message",
                input_schema: Schemas::SEND_MESSAGE_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "teams_oauth:write"
      operation "create_issue",
                input_schema: Schemas::CREATE_ISSUE_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "teams_oauth:write",
                unsupported: true,
                reason: "Teams has no issue tracker; create issues via the github or jira plugin"

      GRAPH_HOST = "graph.microsoft.com"
      GRAPH_BASE = "https://graph.microsoft.com/v1.0"
      CHANNEL_POLL_PATTERN = %r{\Ateam/(?<team>[^/]+)/channel/(?<channel>[^/]+)\z}
      CHAT_POLL_PATTERN = %r{\Achat/(?<chat>[^/]+)\z}
      CHANNEL_SEND_PATTERN = %r{\Achannel:(?<team>[^/]+)/(?<channel>[^/]+)\z}
      CHAT_SEND_PATTERN = %r{\Achat:(?<chat>[^/]+)\z}
      MESSAGE_REPLY_PATTERN = %r{\Amessage:(?<team>[^/]+)/(?<channel>[^/]+)/(?<root>[^/]+)\z}
      CHAT_REPLY_PATTERN = %r{\Achat_message:(?<chat>[^/]+)/(?<message>[^/]+)\z}
      MAX_PAGES = 25
      PER_PAGE = 50
      OVERLAP_SECONDS = 300
      ID_MAX_LENGTH = 512
      ID_FORBIDDEN = %r{[\x00-\x1F\x7F\s/\\]}
      TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):?[0-5]\d)\z/

      # Test seam only: a credential provider used when the trusted context
      # does not carry one. Never switches users or falls back to
      # service-account credentials; the same binding is always resolved.
      def initialize(oauth_credential_provider: nil)
        @injected_provider = oauth_credential_provider
      end

      # Environment settings only; connection success is reported elsewhere.
      def configured?(env)
        present?(env["OAUTH_MICROSOFT_CLIENT_ID"]) &&
          (present?(env["OAUTH_MICROSOFT_CLIENT_SECRET"]) ||
            present?(env["OAUTH_MICROSOFT_CLIENT_SECRET_FILE"])) &&
          present?(env["OAUTH_MICROSOFT_TENANT_ID"]) &&
          present?(env["OAUTH_MICROSOFT_REDIRECT_URI"])
      end

      # Pure shape preflight: no credentials, transport, or mutable state.
      def validate_operation_input(op, input)
        case op.name
        when "latest_events"
          parse_poll_scope(input.fetch("scope"), op.name)
        when "reply"
          parse_reply_target(input.fetch("resource_id"), op.name)
        when "send_message"
          parse_send_target(input.fetch("scope"), op.name)
        end
        nil
      end

      private

      def handle_latest_events(input, ctx)
        poll = parse_poll_scope(input["scope"].to_s, "latest_events")
        cursor = validated_cursor(input, "latest_events")
        since = cursor_since(cursor)
        cutoff = since && since - OVERLAP_SECONDS
        token = oauth_token(ctx, "latest_events")
        headers = {
          "Authorization" => "Bearer #{token}",
          "Accept" => "application/json"
        }

        events, watermark =
          if poll[:kind] == :channel
            poll_channel(ctx, headers, poll, cutoff, since)
          else
            poll_chat(ctx, headers, poll, cutoff, since)
          end

        events.uniq! { |event| [event["event_id"], event["fingerprint"]] }
        events.sort_by! { |event| parse_timestamp(event["occurred_at"]) }
        watermark ||= ctx.clock.now
        { "events" => events, "cursor" => { "since" => timestamp_string(watermark) } }
      end

      def handle_reply(input, ctx)
        target = parse_reply_target(input["resource_id"].to_s, "reply")
        token = oauth_token(ctx, "reply")
        text = input["body"].to_s
        if target[:kind] == :channel
          url = "#{GRAPH_BASE}/teams/#{uri_escape(target[:team])}/channels/" \
                "#{uri_escape(target[:channel])}/messages/#{uri_escape(target[:root])}/replies"
          created = post_graph_message(ctx, token, url, text, "reply")
          { "external_id" => "message:#{target[:team]}/#{target[:channel]}/#{target[:root]}/#{created}",
            "url" => nil }
        else
          url = "#{GRAPH_BASE}/chats/#{uri_escape(target[:chat])}/messages"
          created = post_graph_message(ctx, token, url, text, "reply")
          { "external_id" => "chat_message:#{target[:chat]}/#{created}", "url" => nil }
        end
      end

      def handle_send_message(input, ctx)
        target = parse_send_target(input["scope"].to_s, "send_message")
        token = oauth_token(ctx, "send_message")
        text = input["body"].to_s
        if target[:kind] == :channel
          url = "#{GRAPH_BASE}/teams/#{uri_escape(target[:team])}/channels/" \
                "#{uri_escape(target[:channel])}/messages"
          created = post_graph_message(ctx, token, url, text, "send_message")
          { "external_id" => "message:#{target[:team]}/#{target[:channel]}/#{created}",
            "url" => nil }
        else
          url = "#{GRAPH_BASE}/chats/#{uri_escape(target[:chat])}/messages"
          created = post_graph_message(ctx, token, url, text, "send_message")
          { "external_id" => "chat_message:#{target[:chat]}/#{created}", "url" => nil }
        end
      end

      # -- trusted credential resolution -----------------------------------

      # Resolves the caller-supplied binding through the caller-supplied
      # provider just-in-time. Never re-selects a "current" binding and never
      # touches application/Bot credentials.
      def oauth_token(ctx, operation)
        context = ctx.context.is_a?(Hash) ? ctx.context : {}
        provider = context["oauth_credential_provider"] || context[:oauth_credential_provider] ||
                   @injected_provider
        if provider.nil?
          raise CredentialsMissing.new(plugin: plugin_id,
                                       missing: ["oauth_credential_provider"])
        end
        binding = context["oauth_binding"] || context[:oauth_binding]
        if binding.nil?
          raise CredentialsMissing.new(plugin: plugin_id, missing: ["oauth_binding"])
        end
        check_binding_provider!(binding)

        unless provider.respond_to?(:access_token)
          raise CredentialsMissing.new(plugin: plugin_id,
                                       missing: ["oauth_credential_provider (must provide access_token)"])
        end
        begin
          token = provider.access_token(binding)
        rescue Aiconshell::Oauth::BindingMismatch
          raise CredentialsMissing.new(plugin: plugin_id,
                                       missing: ["oauth_binding (connection changed; reconnect)"])
        rescue Aiconshell::Oauth::Error => e
          raise CredentialsMissing.new(plugin: plugin_id,
                                       missing: ["oauth_binding (connection unavailable: #{e.code})"])
        end
        unless token.is_a?(String) && !token.empty?
          raise OutputInvalid.new(plugin: plugin_id, operation: operation,
                                  details: ["credential provider returned an unexpected token shape"])
        end
        token
      end

      def check_binding_provider!(binding)
        name =
          if binding.is_a?(Hash)
            binding["provider"] || binding[:provider]
          elsif binding.respond_to?(:provider)
            binding.provider
          elsif binding.respond_to?(:to_h)
            hash = binding.to_h
            hash.is_a?(Hash) ? (hash["provider"] || hash[:provider]) : nil
          end
        return if name.nil? || name.to_s == "microsoft"

        raise CredentialsMissing.new(plugin: plugin_id,
                                     missing: ["oauth_binding (microsoft connection required)"])
      end

      # -- scope parsing -----------------------------------------------------

      def parse_poll_scope(scope, operation)
        if (match = CHANNEL_POLL_PATTERN.match(scope.to_s))
          team, channel = match[:team], match[:channel]
          check_ids!(operation, { "team" => team, "channel" => channel })
          { kind: :channel, team: team, channel: channel }
        elsif (match = CHAT_POLL_PATTERN.match(scope.to_s))
          chat = match[:chat]
          check_ids!(operation, { "chat" => chat })
          { kind: :chat, chat: chat }
        else
          raise InputInvalid.new(plugin: plugin_id, operation: operation,
                                 details: ['scope must look like "team/<teamId>/channel/<channelId>" or "chat/<chatId>"'])
        end
      end

      def parse_send_target(scope, operation)
        if (match = CHANNEL_SEND_PATTERN.match(scope.to_s))
          team, channel = match[:team], match[:channel]
          check_ids!(operation, { "team" => team, "channel" => channel })
          { kind: :channel, team: team, channel: channel }
        elsif (match = CHAT_SEND_PATTERN.match(scope.to_s))
          chat = match[:chat]
          check_ids!(operation, { "chat" => chat })
          { kind: :chat, chat: chat }
        else
          raise InputInvalid.new(plugin: plugin_id, operation: operation,
                                 details: ['scope must look like "channel:<teamId>/<channelId>" or "chat:<chatId>"'])
        end
      end

      def parse_reply_target(resource, operation)
        if (match = MESSAGE_REPLY_PATTERN.match(resource.to_s))
          team, channel, root = match[:team], match[:channel], match[:root]
          check_ids!(operation, { "team" => team, "channel" => channel, "root" => root })
          { kind: :channel, team: team, channel: channel, root: root }
        elsif (match = CHAT_REPLY_PATTERN.match(resource.to_s))
          chat, message = match[:chat], match[:message]
          check_ids!(operation, { "chat" => chat, "message" => message })
          { kind: :chat, chat: chat }
        else
          raise InputInvalid.new(plugin: plugin_id, operation: operation,
                                 details: ['resource_id must look like "message:<teamId>/<channelId>/<rootId>" or "chat_message:<chatId>/<messageId>"'])
        end
      end

      # IDs travel as single Graph path segments. Reject anything that could
      # escape the segment (slashes, traversal, whitespace, controls).
      def check_ids!(operation, ids)
        bad = ids.any? do |_, value|
          !value.is_a?(String) || value.empty? || value.length > ID_MAX_LENGTH ||
            value == "." || value == ".." || ID_FORBIDDEN.match?(value) || value.strip.empty?
        end
        return unless bad

        raise InputInvalid.new(plugin: plugin_id, operation: operation,
                               details: ["ids must be single Graph path segments without traversal"])
      end

      # -- channel + chat polling --------------------------------------------

      def poll_channel(ctx, headers, poll, cutoff, since)
        team, channel = poll[:team], poll[:channel]
        first_url = "#{GRAPH_BASE}/teams/#{uri_escape(team)}/channels/" \
                    "#{uri_escape(channel)}/messages?$top=#{PER_PAGE}"
        expected = ["v1.0", "teams", team, "channels", channel, "messages"]
        events = []
        watermark = since
        paged_collection_get(ctx, headers, first_url, expected).each do |message|
          event, modified = channel_event(message, team: team, channel: channel)
          mid = event["payload"]["message_id"]
          events << event unless cutoff && modified < cutoff
          watermark = max_time(watermark, modified)

          # Roots sort by whole-thread activity, not by root age: an old
          # root may carry a brand-new reply, so every root is expanded.
          replies_url = "#{GRAPH_BASE}/teams/#{uri_escape(team)}/channels/" \
                        "#{uri_escape(channel)}/messages/#{uri_escape(mid)}/replies?$top=#{PER_PAGE}"
          paged_collection_get(ctx, headers, replies_url, expected + [mid, "replies"]).each do |reply|
            reply_event, rmodified = channel_event(reply, team: team, channel: channel, root: mid)
            events << reply_event unless cutoff && rmodified < cutoff
            watermark = max_time(watermark, rmodified)
          end
        end
        [events, watermark]
      end

      def poll_chat(ctx, headers, poll, cutoff, since)
        chat = poll[:chat]
        first_url = "#{GRAPH_BASE}/chats/#{uri_escape(chat)}/messages?$top=#{PER_PAGE}"
        expected = ["v1.0", "chats", chat, "messages"]
        events = []
        watermark = since
        paged_collection_get(ctx, headers, first_url, expected).each do |message|
          event, modified = chat_event(message, chat: chat)
          events << event unless cutoff && modified < cutoff
          watermark = max_time(watermark, modified)
        end
        [events, watermark]
      end

      # Follows @odata.nextLink while it stays inside the polled collection.
      # Any page failure raises, so the caller never advances its cursor.
      def paged_collection_get(ctx, headers, first_url, expected_segments)
        items = []
        url = first_url
        seen = {}
        MAX_PAGES.times do
          incomplete!("Graph pagination did not advance") if seen[url]

          seen[url] = true
          response = ctx.transport.request(method: "GET", url: url, headers: headers, body: nil)
          payload = response.json
          values = payload.is_a?(Hash) ? payload["value"] : nil
          unless values.is_a?(Array)
            invalid_output!("Graph response had an unexpected shape")
          end
          items.concat(values)

          nxt = payload.is_a?(Hash) ? payload["@odata.nextLink"] : nil
          return items if nxt.nil? || nxt == ""

          invalid_output!("Graph next link must be a string") unless nxt.is_a?(String)
          url = checked_next_url!(nxt, expected_segments)
        end
        incomplete!("Graph messages or replies exceeded the page limit")
      end

      # Origin plus collection-path pinning: same-host links to another
      # chat, channel, message, or page are refused before any request.
      def checked_next_url!(nxt, expected_segments)
        Http.check_host!(nxt, [GRAPH_BASE])
        uri = URI.parse(nxt)
        if uri.fragment && !uri.fragment.empty?
          invalid_output!("Graph next link must not carry a fragment")
        end
        segments = uri.path.split("/").reject(&:empty?).map do |segment|
          begin
            URI::DEFAULT_PARSER.unescape(segment)
          rescue ArgumentError
            invalid_output!("Graph next link had an unexpected shape")
          end
        end
        unless segments == expected_segments
          invalid_output!("Graph next link pointed outside the polled collection")
        end
        nxt
      rescue URI::InvalidURIError
        invalid_output!("Graph next link had an unexpected shape")
      end

      # Single-shot Graph write. No automatic retry or replay: a 429/401/
      # timeout raises and the caller decides; a post-acceptance crash may
      # duplicate on retry (see plugins/teams_oauth/README.md).
      def post_graph_message(ctx, token, url, text, operation)
        response = ctx.transport.request(
          method: "POST", url: url,
          headers: {
            "Authorization" => "Bearer #{token}",
            "Accept" => "application/json",
            "Content-Type" => "application/json"
          },
          body: JSON.generate({ "body" => { "contentType" => "text", "content" => text } })
        )
        payload = response.json
        id = payload.is_a?(Hash) ? payload["id"] : nil
        unless id.is_a?(String) && !id.empty?
          raise OutputInvalid.new(plugin: plugin_id, operation: operation,
                                  details: ["Graph write response did not include a message id"])
        end
        id
      end

      # -- events --------------------------------------------------------------

      def channel_event(message, team:, channel:, root: nil)
        modified = graph_modified(message)
        mid = message["id"]
        kind = root ? "reply" : "message"
        event_type = root ? "teams_oauth.reply" : "teams_oauth.message"
        identity = [team, channel, root, mid].compact.map { |id| uri_escape(id) }.join("/")
        event = {
          "event_id" => "teams_oauth:#{kind}:#{identity}",
          # Only message content and deletion state identify a revision;
          # reply/reaction metadata may move lastModifiedDateTime and etag.
          "fingerprint" => fingerprint(message.dig("body", "content"),
                                       message.dig("body", "contentType"), message["subject"],
                                       !message["deletedDateTime"].nil?),
          "event_type" => event_type,
          "resource_id" => "message:#{team}/#{channel}/#{root || mid}",
          "actor_id" => graph_actor_id(message["from"]),
          "actor_type" => graph_actor_type(message["from"]),
          "occurred_at" => timestamp_string(modified),
          "payload" => {
            "team_id" => team, "channel_id" => channel,
            "message_id" => mid, "reply_to_id" => root,
            "subject" => message["subject"],
            "content" => message.dig("body", "content"),
            "content_type" => message.dig("body", "contentType"),
            "last_modified" => timestamp_string(modified), "web_url" => message["webUrl"],
            "deleted" => !message["deletedDateTime"].nil?
          }
        }
        [event, modified]
      end

      def chat_event(message, chat:)
        modified = graph_modified(message)
        mid = message["id"]
        identity = [chat, mid].map { |id| uri_escape(id) }.join("/")
        event = {
          "event_id" => "teams_oauth:chat_message:#{identity}",
          "fingerprint" => fingerprint(message.dig("body", "content"),
                                       message.dig("body", "contentType"), message["subject"],
                                       !message["deletedDateTime"].nil?),
          "event_type" => "teams_oauth.chat_message",
          "resource_id" => "chat_message:#{chat}/#{mid}",
          "actor_id" => graph_actor_id(message["from"]),
          "actor_type" => graph_actor_type(message["from"]),
          "occurred_at" => timestamp_string(modified),
          "payload" => {
            "chat_id" => chat,
            "message_id" => mid, "reply_to_id" => nil,
            "subject" => message["subject"],
            "content" => message.dig("body", "content"),
            "content_type" => message.dig("body", "contentType"),
            "last_modified" => timestamp_string(modified), "web_url" => message["webUrl"],
            "deleted" => !message["deletedDateTime"].nil?
          }
        }
        [event, modified]
      end

      def graph_modified(message)
        unless message.is_a?(Hash) && message["id"].is_a?(String) && !message["id"].empty? &&
               message["body"].is_a?(Hash)
          invalid_output!("Graph message had an unexpected shape")
        end
        parse_timestamp(message["lastModifiedDateTime"] || message["createdDateTime"])
      end

      def graph_actor_id(from)
        return "unknown" unless from.is_a?(Hash)

        user = from["user"]
        return user["id"].to_s if user.is_a?(Hash) && user["id"]

        app = from["application"]
        return "app:#{app["id"]}" if app.is_a?(Hash) && app["id"]

        "unknown"
      end

      def graph_actor_type(from)
        return "system" unless from.is_a?(Hash)
        return "human" if from["user"].is_a?(Hash)
        return "bot" if from["application"].is_a?(Hash)

        "system"
      end

      def cursor_since(cursor)
        unless (cursor.keys - ["since"]).empty?
          raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                 details: ["cursor only supports since; restart incomplete polls from the previous cursor"])
        end
        since = cursor["since"]
        return nil if since.nil?

        parse_timestamp(since, input: true)
      end

      def max_time(current, candidate)
        current.nil? || candidate > current ? candidate : current
      end

      def parse_timestamp(value, input: false)
        raise ArgumentError unless value.is_a?(String) && TIMESTAMP_PATTERN.match?(value)

        Date.iso8601(value[0, 10])
        Time.iso8601(value).utc
      rescue ArgumentError
        error = input ? InputInvalid : OutputInvalid
        raise error.new(plugin: plugin_id, operation: "latest_events",
                        details: [input ? "cursor.since must be a valid ISO8601 timestamp" : "Graph returned an invalid timestamp"])
      end

      def timestamp_string(time)
        time.utc.iso8601(6).sub(/\.000000Z\z/, "Z")
      end

      def invalid_output!(reason)
        raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events", details: [reason])
      end

      def incomplete!(reason)
        raise IncompletePoll.new(plugin: plugin_id, operation: "latest_events", reason: reason)
      end

      def uri_escape(value)
        URI.encode_www_form_component(value.to_s)
      end
    end
  end
end
