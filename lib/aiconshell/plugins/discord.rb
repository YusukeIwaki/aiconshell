# frozen_string_literal: true

require "date"
require "json"
require "time"
require "uri"

module Aiconshell
  module Plugins
    # Discord Bot adapter (Discord REST API v10, fixed origin).
    #
    # Authentication is a Bot token from DISCORD_BOT_TOKEN only. No user
    # tokens, OAuth delegation, or webhook credentials are used. The bot's
    # own user id is resolved per poll through an authenticated
    # GET /users/@me call; no Bot ID environment variable is required.
    #
    # Poll scope: "channel/<channelId>". Reply resource:
    # "message:<channelId>/<messageId>". Send scope: "channel:<channelId>".
    # Channel and message ids are Discord snowflakes and are strictly
    # validated everywhere (shape, range, channel consistency), so URLs,
    # path traversal, and cross-channel responses are rejected.
    #
    # Only human messages whose structured `mentions` array contains the
    # bot's own id become events. Body-text pseudo-mentions, mentions of
    # other bots, plain messages, and self/bot/webhook/system messages never
    # become events, so they can never start new tasks or reply loops.
    # create_issue is explicitly unsupported: Discord has no issue tracker.
    class Discord < Base
      plugin_id "discord"
      required_env "DISCORD_BOT_TOKEN"

      REPLY_INPUT = {
        "type" => "object",
        "required" => %w[resource_id body],
        "properties" => {
          "resource_id" => { "type" => "string",
                             "pattern" => '\\Amessage:[1-9][0-9]{0,19}/[1-9][0-9]{0,19}\\z' },
          "body" => { "type" => "string", "minLength" => 1, "maxLength" => 2000 }
        },
        "additionalProperties" => false
      }.freeze

      SEND_MESSAGE_INPUT = {
        "type" => "object",
        "required" => %w[scope body],
        "properties" => {
          "scope" => { "type" => "string", "pattern" => '\\Achannel:[1-9][0-9]{0,19}\\z' },
          "body" => { "type" => "string", "minLength" => 1, "maxLength" => 2000 }
        },
        "additionalProperties" => false
      }.freeze

      operation "latest_events",
                input_schema: Schemas::LATEST_EVENTS_INPUT,
                output_schema: Schemas::LATEST_EVENTS_OUTPUT,
                scope: "discord:read",
                read_only: true
      operation "reply",
                input_schema: REPLY_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "discord:write"
      operation "send_message",
                input_schema: SEND_MESSAGE_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "discord:write"
      operation "create_issue",
                input_schema: Schemas::CREATE_ISSUE_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "discord:write",
                unsupported: true,
                reason: "Discord has no issue tracker; create issues via the github or jira plugin"

      API_ORIGIN = "https://discord.com"
      API_BASE = "https://discord.com/api/v10"
      USER_AGENT = "aiconshell-discord-plugin/0.1.0"
      PER_PAGE = 100
      MAX_PAGES = 10
      MAX_BODY_CHARS = 2000
      SNOWFLAKE_MAX = ((1 << 64) - 1).freeze
      SCOPE_PATTERN = %r{\Achannel/(?<channel>[^/]+)\z}
      SEND_SCOPE_PATTERN = %r{\Achannel:(?<channel>.+)\z}
      REPLY_PATTERN = %r{\Amessage:(?<channel>[^/]+)/(?<message>[^/]+)\z}
      TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):?[0-5]\d)\z/
      # Discord user-authored message types. Everything else (pins, joins,
      # boosts, thread creation notices, ...) is a system message.
      USER_MESSAGE_TYPES = [0, 19].freeze

      class << self
        # Strict Discord snowflake check: canonical decimal digits only, no
        # leading zeros, within the uint64 range.
        def valid_snowflake?(value)
          text = value.to_s
          return false unless text.match?(/\A[1-9][0-9]*\z/) && text.length <= 20

          integer = text.to_i
          integer >= 1 && integer <= SNOWFLAKE_MAX
        end
      end

      # Pure semantic preflight: shape, snowflake range, and body-length
      # checks only. No credentials, transport, clock, or mutable state.
      def validate_operation_input(op, input)
        case op.name
        when "latest_events"
          check_poll_scope(input["scope"])
          check_cursor(input["cursor"])
        when "reply"
          match = REPLY_PATTERN.match(input["resource_id"].to_s)
          unless match && self.class.valid_snowflake?(match[:channel]) &&
                 self.class.valid_snowflake?(match[:message])
            raise InputInvalid.new(plugin: plugin_id, operation: op.name,
                                   details: ['resource_id must look like "message:<channelId>/<messageId>" with Discord snowflake ids'])
          end
          check_body(input["body"], op.name)
        when "send_message"
          match = SEND_SCOPE_PATTERN.match(input["scope"].to_s)
          unless match && self.class.valid_snowflake?(match[:channel])
            raise InputInvalid.new(plugin: plugin_id, operation: op.name,
                                   details: ['scope must look like "channel:<channelId>" with a Discord snowflake id'])
          end
          check_body(input["body"], op.name)
        end
      end

      def configured?(env)
        present?(env["DISCORD_BOT_TOKEN"])
      end

      private

      def handle_latest_events(input, ctx)
        channel = check_poll_scope(input["scope"])
        after = check_cursor(input["cursor"])
        bot_id = fetch_self_id(ctx)
        headers = auth_headers(ctx.env)

        events = []
        watermark = after.nil? ? nil : after.to_i
        finished = false
        seen = {}
        url = "#{API_BASE}/channels/#{channel}/messages?limit=#{PER_PAGE}"
        MAX_PAGES.times do
          incomplete!("Discord pagination did not advance") if seen[url]

          seen[url] = true
          messages = get_message_list(ctx, headers, url)
          if messages.empty?
            finished = true
            break
          end

          ids = []
          messages.each do |message|
            id, event = message_event(message, channel: channel, bot_id: bot_id)
            ids << id
            events << event unless event.nil?
          end
          watermark = ids.map(&:to_i).max if watermark.nil? || ids.map(&:to_i).max > watermark
          oldest = ids.map(&:to_i).min

          if !after.nil? && oldest <= after.to_i
            finished = true
            break
          end
          if messages.size < PER_PAGE
            finished = true
            break
          end

          url = "#{API_BASE}/channels/#{channel}/messages?limit=#{PER_PAGE}&before=#{oldest}"
        end
        incomplete!("Discord backlog exceeded the page limit; narrow the channel or retry after processing") unless finished

        events.uniq! { |event| [event["event_id"], event["fingerprint"]] }
        events.sort_by! { |event| parse_timestamp(event["occurred_at"]) }
        cursor = watermark.nil? ? {} : { "after" => watermark.to_s }
        { "events" => events, "cursor" => cursor }
      end

      def handle_reply(input, ctx)
        match = REPLY_PATTERN.match(input["resource_id"].to_s)
        unless match && self.class.valid_snowflake?(match[:channel]) &&
               self.class.valid_snowflake?(match[:message])
          raise InputInvalid.new(plugin: plugin_id, operation: "reply",
                                 details: ['resource_id must look like "message:<channelId>/<messageId>" with Discord snowflake ids'])
        end
        post_message(ctx, match[:channel], input["body"].to_s, "reply", reply_to: match[:message])
      end

      def handle_send_message(input, ctx)
        match = SEND_SCOPE_PATTERN.match(input["scope"].to_s)
        unless match && self.class.valid_snowflake?(match[:channel])
          raise InputInvalid.new(plugin: plugin_id, operation: "send_message",
                                 details: ['scope must look like "channel:<channelId>" with a Discord snowflake id'])
        end
        post_message(ctx, match[:channel], input["body"].to_s, "send_message", reply_to: nil)
      end

      # -- reads ------------------------------------------------------------

      def check_poll_scope(scope)
        match = SCOPE_PATTERN.match(scope.to_s)
        unless match && self.class.valid_snowflake?(match[:channel])
          raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                 details: ['scope must look like "channel/<channelId>" with a Discord snowflake id'])
        end
        match[:channel]
      end

      def check_cursor(cursor)
        return nil if cursor.nil?

        normalized = validated_cursor({ "cursor" => cursor }, "latest_events")
        unless (normalized.keys - ["after"]).empty?
          raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                 details: ["cursor only supports after; restart incomplete polls from the previous cursor"])
        end
        after = normalized["after"]
        return nil if after.nil?
        unless after.is_a?(String) && self.class.valid_snowflake?(after)
          raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                 details: ["cursor.after must be a Discord snowflake id"])
        end
        after
      end

      # Resolve the bot's own user id with the configured Bot token. Never
      # inferred from message text.
      def fetch_self_id(ctx)
        response = ctx.transport.request(method: "GET", url: "#{API_BASE}/users/@me",
                                         headers: auth_headers(ctx.env), body: nil)
        payload = Http.strict_json!(response.body, plugin: plugin_id, operation: "latest_events")
        unless payload.is_a?(Hash) && self.class.valid_snowflake?(payload["id"])
          raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                  details: ["Discord user response had an unexpected shape"])
        end
        payload["id"].to_s
      end

      def get_message_list(ctx, headers, url)
        response = ctx.transport.request(method: "GET", url: url, headers: headers, body: nil)
        payload = Http.strict_json!(response.body, plugin: plugin_id, operation: "latest_events")
        unless payload.is_a?(Array)
          raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                  details: ["Discord message list had an unexpected shape"])
        end
        payload
      end

      # Returns [snowflakeId, eventOrNil]. Malformed messages and messages
      # from another channel raise; non-mention, bot, webhook, and system
      # messages return nil so they never start tasks or reply loops.
      def message_event(message, channel:, bot_id:)
        unless message.is_a?(Hash) && self.class.valid_snowflake?(message["id"]) &&
               message["channel_id"].is_a?(String)
          invalid_output!("Discord message had an unexpected shape")
        end
        id = message["id"].to_s
        if message["channel_id"] != channel
          invalid_output!("Discord response contained a message from another channel")
        end

        author = message["author"]
        unless author.is_a?(Hash) && self.class.valid_snowflake?(author["id"])
          invalid_output!("Discord message had an unexpected shape")
        end

        mentions = message["mentions"]
        unless mentions.is_a?(Array)
          invalid_output!("Discord message had an unexpected shape")
        end

        timestamp = parse_timestamp(message["timestamp"])
        edited_raw = message["edited_timestamp"]
        edited = edited_raw.nil? ? nil : parse_timestamp(edited_raw)
        occurred = edited && edited > timestamp ? edited : timestamp

        mentioned = mentions.any? { |entry| entry.is_a?(Hash) && entry["id"].to_s == bot_id }
        human = author["bot"] != true && message["webhook_id"].nil?
        user_type = message["type"].is_a?(Integer) && USER_MESSAGE_TYPES.include?(message["type"])
        return [id, nil] unless human && user_type && mentioned

        content = message["content"]
        unless content.is_a?(String)
          invalid_output!("Discord message had an unexpected shape")
        end
        username = author["username"]
        unless username.is_a?(String)
          invalid_output!("Discord message had an unexpected shape")
        end

        event = {
          "event_id" => "discord:message:#{channel}/#{id}",
          # Content plus edit time identify a revision, so A -> B -> A
          # edits surface as distinct revisions downstream.
          "fingerprint" => fingerprint(content, edited_raw),
          "event_type" => "discord.message",
          "resource_id" => "message:#{channel}/#{id}",
          "actor_id" => author["id"].to_s,
          "actor_type" => "human",
          "occurred_at" => timestamp_string(occurred),
          "payload" => {
            "channel_id" => channel, "message_id" => id,
            "body" => content,
            "author_id" => author["id"].to_s, "author_username" => username,
            "author_display_name" => author["global_name"].is_a?(String) ? author["global_name"] : username,
            "mentions" => mentions.filter_map { |entry| entry["id"].to_s if entry.is_a?(Hash) && entry["id"] },
            "message_type" => message["type"],
            "edited" => !edited.nil?,
            "timestamp" => timestamp_string(timestamp),
            "edited_timestamp" => edited.nil? ? nil : timestamp_string(edited)
          }
        }
        [id, event]
      end

      # -- writes -----------------------------------------------------------

      def post_message(ctx, channel, text, operation, reply_to:)
        token = bot_token(ctx.env)
        url = "#{API_BASE}/channels/#{channel}/messages"
        payload = { "content" => text,
                    "allowed_mentions" => { "parse" => [], "replied_user" => false } }
        payload["message_reference"] = { "message_id" => reply_to } unless reply_to.nil?
        response = ctx.transport.request(
          method: "POST", url: url,
          headers: {
            "Authorization" => "Bot #{token}",
            "Accept" => "application/json",
            "Content-Type" => "application/json",
            "User-Agent" => USER_AGENT
          },
          body: JSON.generate(payload)
        )
        result = Http.strict_json!(response.body, plugin: plugin_id, operation: operation)
        unless result.is_a?(Hash) && result["id"].is_a?(String) && self.class.valid_snowflake?(result["id"])
          raise OutputInvalid.new(plugin: plugin_id, operation: operation,
                                  details: ["Discord response did not include a message id"])
        end

        { "external_id" => result["id"].to_s, "url" => nil }
      end

      def auth_headers(env)
        {
          "Authorization" => "Bot #{bot_token(env)}",
          "Accept" => "application/json",
          "User-Agent" => USER_AGENT
        }
      end

      def bot_token(env)
        token = env["DISCORD_BOT_TOKEN"]
        require_credentials!(["DISCORD_BOT_TOKEN"]) if token.nil? || token.to_s.empty?

        token.to_s
      end

      # -- helpers ----------------------------------------------------------

      def check_body(body, operation)
        unless body.is_a?(String) && body.length >= 1 && body.length <= MAX_BODY_CHARS
          raise InputInvalid.new(plugin: plugin_id, operation: operation,
                                 details: ["body must be 1-#{MAX_BODY_CHARS} characters for Discord"])
        end
      end

      def parse_timestamp(value, input: false)
        raise ArgumentError unless value.is_a?(String) && TIMESTAMP_PATTERN.match?(value)

        Date.iso8601(value[0, 10])
        Time.iso8601(value).utc
      rescue ArgumentError
        error = input ? InputInvalid : OutputInvalid
        raise error.new(plugin: plugin_id, operation: "latest_events",
                        details: [input ? "cursor timestamp must be a valid ISO8601 timestamp" : "Discord returned an invalid timestamp"])
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
    end
  end
end
