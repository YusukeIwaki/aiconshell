# frozen_string_literal: true

require "date"
require "json"
require "time"
require "uri"

module Aiconshell
  module Plugins
    # Microsoft Teams adapter.
    #
    # Reads go through Microsoft Graph with application auth
    # (client credentials): channel messages + replies polling. Writes go
    # through the Bot Connector (proactive messages) with bot credentials.
    # Normal posting never uses Graph import/migration endpoints.
    #
    # Poll scope: "team/<teamId>/channel/<channelId>".
    # latest_events cursor: {"since": ISO8601}. All roots and replies are
    # traversed before advancing it. Write targets use an actual Bot
    # conversation reference, or a trusted mapping from a Graph resource id.
    # create_issue is explicitly unsupported: Teams has no issue tracker.
    class Teams < Base
      plugin_id "teams"
      required_env "TEAMS_TENANT_ID", "TEAMS_CLIENT_ID",
                   "TEAMS_CLIENT_SECRET", "TEAMS_CLIENT_SECRET_FILE",
                   "TEAMS_BOT_APP_ID", "TEAMS_BOT_APP_PASSWORD",
                   "TEAMS_BOT_APP_PASSWORD_FILE", "TEAMS_SERVICE_URL",
                   "TEAMS_BOT_TARGETS_FILE"

      operation "latest_events",
                input_schema: Schemas::LATEST_EVENTS_INPUT,
                output_schema: Schemas::LATEST_EVENTS_OUTPUT,
                scope: "teams:read",
                read_only: true
      operation "reply",
                input_schema: Schemas::REPLY_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "teams:write"
      operation "send_message",
                input_schema: Schemas::SEND_MESSAGE_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "teams:write"
      operation "create_issue",
                input_schema: Schemas::CREATE_ISSUE_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "teams:write",
                unsupported: true,
                reason: "Teams has no issue tracker; create issues via the github or jira plugin"

      GRAPH_URL_DEFAULT = "https://graph.microsoft.com"
      LOGIN_HOST = "login.microsoftonline.com"
      GRAPH_SCOPE = "https://graph.microsoft.com/.default"
      BOT_SCOPE = "https://api.botframework.com/.default"
      SCOPE_PATTERN = %r{\Ateam/(?<team>[^/]+)/channel/(?<channel>[^/]+)\z}
      CONVERSATION_PATTERN = %r{\Aconversation:(?<id>[^/]+)(/(?<activity>.+))?\z}
      CHANNEL_PATTERN = %r{\Achannel:(?<team>[^/]+)/(?<channel>[^/]+)\z}
      MESSAGE_PATTERN = %r{\Amessage:(?<team>[^/]+)/(?<channel>[^/]+)/(?<root>[^/]+)\z}
      MAX_PAGES = 25
      PER_PAGE = 50
      OVERLAP_SECONDS = 300
      TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):?[0-5]\d)\z/
      BOT_TARGETS_SCHEMA = {
        "type" => "object",
        "additionalProperties" => {
          "type" => "object", "required" => ["conversation_id"],
          "properties" => {
            "conversation_id" => { "type" => "string", "minLength" => 1 },
            "activity_id" => { "type" => "string", "minLength" => 1 }
          },
          "additionalProperties" => false
        }
      }.freeze

      # Read credentials make the plugin usable for polling; write operations
      # additionally require bot credentials + service URL at call time.
      def validate_operation_input(op, input)
        return unless %w[reply send_message].include?(op.name)

        value = input.fetch(op.name == "reply" ? "resource_id" : "scope")
        return if CONVERSATION_PATTERN.match?(value) || CHANNEL_PATTERN.match?(value) ||
          (op.name == "reply" && MESSAGE_PATTERN.match?(value))

        raise InputInvalid.new(plugin: plugin_id, operation: op.name,
          details: ['target must look like "conversation:<id>" or "channel:<teamId>/<channelId>"; reply also accepts a mapped "message:<teamId>/<channelId>/<rootMessageId>"'])
      end

      def configured?(env)
        present?(env["TEAMS_TENANT_ID"]) &&
          present?(env["TEAMS_CLIENT_ID"]) &&
          (present?(env["TEAMS_CLIENT_SECRET"]) || present?(env["TEAMS_CLIENT_SECRET_FILE"]))
      end

      private

      def handle_latest_events(input, ctx)
        match = SCOPE_PATTERN.match(input["scope"].to_s)
        unless match
          raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                 details: ['scope must look like "team/<teamId>/channel/<channelId>"'])
        end

        cursor = validated_cursor(input, "latest_events")
        since = cursor_since(cursor)
        cutoff = since && since - OVERLAP_SECONDS
        graph = graph_base(ctx.env)
        token = app_token(ctx, audience: :graph)
        headers = {
          "Authorization" => "Bearer #{token}",
          "Accept" => "application/json"
        }

        first_url = "#{graph}/v1.0/teams/#{uri_escape(match[:team])}/channels/#{uri_escape(match[:channel])}" \
                    "/messages?$top=#{PER_PAGE}"

        events = []
        watermark = since
        messages = paged_graph_get(ctx, headers, first_url, [graph])
        messages.each do |message|
          event, modified = message_event(message, team: match[:team], channel: match[:channel])
          mid = event["payload"]["message_id"]
          events << event unless cutoff && modified < cutoff
          watermark = max_time(watermark, modified)

          # Roots are ordered by their whole reply chain, not by the root's
          # timestamp. Never stop at an old root: it may have a brand-new reply.
          replies_url =
            "#{graph}/v1.0/teams/#{uri_escape(match[:team])}/channels/#{uri_escape(match[:channel])}" \
            "/messages/#{uri_escape(mid)}/replies?$top=#{PER_PAGE}"
          paged_graph_get(ctx, headers, replies_url, [graph]).each do |reply|
            reply_event, rmodified = message_event(reply, team: match[:team], channel: match[:channel], root: mid)
            events << reply_event unless cutoff && rmodified < cutoff
            watermark = max_time(watermark, rmodified)
          end
        end

        events.uniq! { |event| [event["event_id"], event["fingerprint"]] }
        events.sort_by! { |event| parse_timestamp(event["occurred_at"]) }
        watermark ||= ctx.clock.now
        { "events" => events, "cursor" => { "since" => timestamp_string(watermark) } }
      end

      def handle_reply(input, ctx)
        target = parse_write_target(input["resource_id"].to_s, "reply", ctx)
        post_activity(ctx, target, input["body"].to_s, "reply")
      end

      def handle_send_message(input, ctx)
        target = parse_write_target(input["scope"].to_s, "send_message", ctx)
        post_activity(ctx, target, input["body"].to_s, "send_message")
      end

      # -- writes (Bot Connector) ------------------------------------------

      def parse_write_target(value, operation, ctx)
        if (match = CONVERSATION_PATTERN.match(value))
          return { conversation_id: match[:id], reply_to: match[:activity] }
        end
        message_target = operation == "reply" && MESSAGE_PATTERN.match?(value)
        if CHANNEL_PATTERN.match?(value) || message_target
          target = bot_targets(ctx)[value]
          unless target && (!message_target || present?(target["activity_id"]))
            require_credentials!(["TEAMS_BOT_TARGETS_FILE or trusted teams_bot_targets mapping for this target"])
          end
          return { conversation_id: target["conversation_id"], reply_to: target["activity_id"] }
        end

        raise InputInvalid.new(plugin: plugin_id, operation: operation,
                               details: ['target must look like "conversation:<id>" or ' \
                                         '"channel:<teamId>/<channelId>"; reply also accepts a mapped "message:<teamId>/<channelId>/<rootMessageId>"'])
      end

      # Only trusted application configuration supplies Bot references. Graph
      # IDs alone cannot identify an arbitrary Bot conversation or activity.
      def bot_targets(ctx)
        targets = ctx.context["teams_bot_targets"] || ctx.context[:teams_bot_targets]
        if targets.nil?
          path = ctx.env["TEAMS_BOT_TARGETS_FILE"]
          require_credentials!(["TEAMS_BOT_TARGETS_FILE or trusted teams_bot_targets mapping"]) unless present?(path)
          targets = JSON.parse(File.read(path.to_s))
        end
        unless Schemas.error_details(BOT_TARGETS_SCHEMA, targets).empty?
          require_credentials!(["TEAMS_BOT_TARGETS_FILE or teams_bot_targets must contain valid Bot references"])
        end
        targets
      rescue JSON::ParserError, SystemCallError
        require_credentials!(["TEAMS_BOT_TARGETS_FILE (readable JSON object required)"])
      end

      def post_activity(ctx, target, text, operation)
        service_url, = bot_service(ctx.env)
        token = app_token(ctx, audience: :bot)
        url = "#{service_url}/v3/conversations/#{uri_escape(target[:conversation_id])}/activities"
        activity = { "type" => "message", "text" => text }
        if target[:reply_to]
          url += "/#{uri_escape(target[:reply_to])}"
          activity["replyToId"] = target[:reply_to]
        end
        response = ctx.transport.request(
          method: "POST", url: url,
          headers: {
            "Authorization" => "Bearer #{token}",
            "Accept" => "application/json",
            "Content-Type" => "application/json"
          },
          body: JSON.generate(activity)
        )
        payload = response.json
        unless payload.is_a?(Hash) && payload["id"]
          raise OutputInvalid.new(plugin: plugin_id, operation: operation,
                                  details: ["Bot Connector response did not include an activity id"])
        end

        { "external_id" => payload["id"].to_s, "url" => nil }
      end

      def bot_service(env)
        raw = env["TEAMS_SERVICE_URL"]
        if raw.nil? || raw.to_s.strip.empty?
          require_credentials!(["TEAMS_SERVICE_URL"])
        end

        begin
          uri = URI.parse(raw.to_s.strip.chomp("/"))
        rescue URI::InvalidURIError
          uri = nil
        end
        unless uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty? &&
               uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
          raise CredentialsMissing.new(plugin: plugin_id,
                                       missing: ["TEAMS_SERVICE_URL (must be an https URL)"])
        end

        ["#{uri.scheme}://#{uri.host}#{":#{uri.port}" if uri.port != uri.default_port}#{uri.path}",
         uri.host.downcase]
      end

      # -- auth (Microsoft identity platform, client credentials) ----------

      def graph_base(env)
        raw = env["TEAMS_GRAPH_URL"]
        raw = GRAPH_URL_DEFAULT if raw.nil? || raw.to_s.strip.empty?
        begin
          uri = URI.parse(raw.to_s.strip.chomp("/"))
        rescue URI::InvalidURIError
          uri = nil
        end
        unless uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty? &&
               uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
          raise CredentialsMissing.new(plugin: plugin_id,
                                       missing: ["TEAMS_GRAPH_URL (must be an https URL)"])
        end

        "#{uri.scheme}://#{uri.host}#{":#{uri.port}" if uri.port != uri.default_port}#{uri.path}"
      end

      # Cached per-audience app token. Graph reads use the Teams app identity;
      # Bot Connector writes use the bot identity (often the same app).
      def app_token(ctx, audience:)
        env = ctx.env
        @token_mutex ||= Mutex.new
        @token_mutex.synchronize do
          @token_cache ||= {}
          cached = @token_cache[audience]
          if cached && cached[:key] == token_cache_key(env, audience) &&
             cached[:expires_at] > ctx.clock.now
            return cached[:token]
          end

          token, expires_in = fetch_app_token(ctx, audience: audience)
          @token_cache[audience] = {
            key: token_cache_key(env, audience),
            token: token,
            expires_at: ctx.clock.now + expires_in - 60
          }
          token
        end
      end

      def token_cache_key(env, audience)
        if audience == :graph
          ["graph", env["TEAMS_TENANT_ID"].to_s, env["TEAMS_CLIENT_ID"].to_s,
           Digest::SHA256.hexdigest((secret_from(env, "TEAMS_CLIENT_SECRET",
                                                 "TEAMS_CLIENT_SECRET_FILE") || "").to_s)]
        else
          ["bot", env["TEAMS_TENANT_ID"].to_s, bot_app_id(env),
           Digest::SHA256.hexdigest((bot_password(env) || "").to_s)]
        end
      end

      def fetch_app_token(ctx, audience:)
        env = ctx.env
        tenant = env["TEAMS_TENANT_ID"]
        if tenant.nil? || tenant.to_s.strip.empty?
          require_credentials!(["TEAMS_TENANT_ID"])
        end

        client_id, secret, missing = if audience == :graph
                                       [env["TEAMS_CLIENT_ID"],
                                        secret_from(env, "TEAMS_CLIENT_SECRET", "TEAMS_CLIENT_SECRET_FILE"),
                                        ["TEAMS_CLIENT_ID", "TEAMS_CLIENT_SECRET or TEAMS_CLIENT_SECRET_FILE"]]
                                     else
                                       [bot_app_id(env), bot_password(env),
                                        ["TEAMS_BOT_APP_ID", "TEAMS_BOT_APP_PASSWORD or TEAMS_BOT_APP_PASSWORD_FILE"]]
                                     end
        lacking = []
        lacking << missing[0] if client_id.nil? || client_id.to_s.empty?
        lacking << missing[1] if secret.nil? || secret.to_s.empty?
        require_credentials!(lacking)

        scope = audience == :graph ? GRAPH_SCOPE : BOT_SCOPE
        url = "https://#{LOGIN_HOST}/#{uri_escape(tenant.to_s.strip)}/oauth2/v2.0/token"
        form = URI.encode_www_form({ "client_id" => client_id.to_s,
                                     "client_secret" => secret.to_s,
                                     "scope" => scope,
                                     "grant_type" => "client_credentials" })
        response = ctx.transport.request(
          method: "POST", url: url,
          headers: { "Accept" => "application/json",
                     "Content-Type" => "application/x-www-form-urlencoded" },
          body: form
        )
        payload = response.json
        unless payload.is_a?(Hash) && payload["access_token"]
          raise OutputInvalid.new(plugin: plugin_id, operation: ctx.operation,
                                  details: ["Microsoft token response had an unexpected shape"])
        end

        [payload["access_token"].to_s, (payload["expires_in"] || 3600).to_i]
      end

      # Bot identity defaults to the Teams app identity when dedicated bot
      # variables are absent, since both are usually the same Entra app.
      def bot_app_id(env)
        id = env["TEAMS_BOT_APP_ID"]
        id = env["TEAMS_CLIENT_ID"] if id.nil? || id.to_s.empty?
        id
      end

      def bot_password(env)
        secret = secret_from(env, "TEAMS_BOT_APP_PASSWORD", "TEAMS_BOT_APP_PASSWORD_FILE")
        return secret unless secret.nil? || secret.empty?

        secret_from(env, "TEAMS_CLIENT_SECRET", "TEAMS_CLIENT_SECRET_FILE")
      end

      # -- reads (Graph) ----------------------------------------------------

      # Follow @odata.nextLink URLs with host validation. Any page failure
      # raises, so the caller never advances its cursor.
      def paged_graph_get(ctx, headers, first_url, allowed_hosts)
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
          Http.check_host!(nxt, allowed_hosts)
          url = nxt
        end
        incomplete!("Graph messages or replies exceeded the page limit")
      end

      # -- helpers ----------------------------------------------------------

      def message_event(message, team:, channel:, root: nil)
        unless message.is_a?(Hash) && message["id"].is_a?(String) && !message["id"].empty? &&
               message["body"].is_a?(Hash)
          invalid_output!("Graph message had an unexpected shape")
        end
        modified = parse_timestamp(message["lastModifiedDateTime"] || message["createdDateTime"])
        mid = message["id"]
        kind = root ? "reply" : "message"
        identity = [team, channel, root, mid].compact.map { |id| uri_escape(id) }.join("/")
        event = {
          "event_id" => "teams:#{kind}:#{identity}",
          # Replies/reactions may change lastModifiedDateTime and etag on the
          # parent. Only message content and deletion state identify a revision.
          "fingerprint" => fingerprint(message.dig("body", "content"),
                                       message.dig("body", "contentType"), message["subject"],
                                       !message["deletedDateTime"].nil?),
          "event_type" => "teams.#{kind}",
          "resource_id" => "message:#{team}/#{channel}/#{root || mid}",
          "actor_id" => teams_actor_id(message["from"]),
          "actor_type" => teams_actor_type(message["from"]),
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

      def teams_actor_id(from)
        return "unknown" unless from.is_a?(Hash)

        user = from["user"]
        return user["id"].to_s if user.is_a?(Hash) && user["id"]

        app = from["application"]
        return "app:#{app["id"]}" if app.is_a?(Hash) && app["id"]

        "unknown"
      end

      def teams_actor_type(from)
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
