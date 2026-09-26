# frozen_string_literal: true

require "json"
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
    # latest_events cursor: {"since": ISO8601, "next": optional resume URL}.
    # Write targets: "conversation/<id>" (bot conversation reference; a Teams
    # channel id doubles as its channel conversation id) or
    # "channel/<teamId>/<channelId>". Polled message events carry
    # resource_id "message/<teamId>/<channelId>/<messageId>" plus payload ids
    # so the app can correlate them with stored bot conversation references.
    # create_issue is explicitly unsupported: Teams has no issue tracker.
    class Teams < Base
      plugin_id "teams"
      required_env "TEAMS_TENANT_ID", "TEAMS_CLIENT_ID",
                   "TEAMS_CLIENT_SECRET", "TEAMS_CLIENT_SECRET_FILE",
                   "TEAMS_BOT_APP_ID", "TEAMS_BOT_APP_PASSWORD",
                   "TEAMS_BOT_APP_PASSWORD_FILE", "TEAMS_SERVICE_URL"

      operation "latest_events",
                input_schema: Schemas::LATEST_EVENTS_INPUT,
                output_schema: Schemas::LATEST_EVENTS_OUTPUT,
                scope: "teams:read"
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
      CHANNEL_PATTERN = %r{\Achannel:(?<team>[^/]+)/(?<channel>[^/]+)(/(?<activity>.+))?\z}
      MAX_PAGES = 25
      MAX_EXPANDED_MESSAGES = 50
      PER_PAGE = 50

      # Read credentials make the plugin usable for polling; write operations
      # additionally require bot credentials + service URL at call time.
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
        graph = graph_base(ctx.env)
        graph_host = URI.parse(graph).host.to_s.downcase
        # Validate a caller-supplied resume URL before any external I/O so a
        # hostile cursor can never cause a credentialed request elsewhere.
        Http.check_host!(cursor["next"].to_s, [graph_host]) if cursor["next"]
        token = app_token(ctx, audience: :graph)
        headers = {
          "Authorization" => "Bearer #{token}",
          "Accept" => "application/json"
        }

        filter = since ? "&$filter=#{uri_escape("lastModifiedDateTime gt #{since}")}" : ""
        first_url = if cursor["next"]
                      Http.check_host!(cursor["next"].to_s, [graph_host])
                      cursor["next"].to_s
                    else
                      "#{graph}/v1.0/teams/#{uri_escape(match[:team])}/channels/#{uri_escape(match[:channel])}" \
                        "/messages?$top=#{PER_PAGE}#{filter}"
                    end

        events = []
        watermark = since
        messages = paged_graph_get(ctx, headers, first_url, [graph_host])
        messages.first(MAX_EXPANDED_MESSAGES).each do |message|
          modified = (message["lastModifiedDateTime"] || message["createdDateTime"]).to_s
          mid = message["id"].to_s
          events << {
            "event_id" => "teams:message:#{mid}",
            "fingerprint" => fingerprint(modified, message.dig("body", "content"),
                                         message["etag"], message.dig("body", "contentType")),
            "event_type" => "teams.message",
            "resource_id" => "message:#{match[:team]}/#{match[:channel]}/#{mid}",
            "actor_id" => teams_actor_id(message["from"]),
            "actor_type" => teams_actor_type(message["from"]),
            "occurred_at" => message["createdDateTime"].to_s,
            "payload" => {
              "team_id" => match[:team], "channel_id" => match[:channel],
              "message_id" => mid, "reply_to_id" => message["replyToId"],
              "subject" => message["subject"],
              "content" => message.dig("body", "content"),
              "content_type" => message.dig("body", "contentType"),
              "last_modified" => modified,
              "web_url" => message["webUrl"]
            }
          }
          watermark = max_time(watermark, modified)

          replies_url =
            "#{graph}/v1.0/teams/#{uri_escape(match[:team])}/channels/#{uri_escape(match[:channel])}" \
            "/messages/#{uri_escape(mid)}/replies?$top=#{PER_PAGE}#{filter}"
          paged_graph_get(ctx, headers, replies_url, [graph_host]).each do |reply|
            rmodified = (reply["lastModifiedDateTime"] || reply["createdDateTime"]).to_s
            rid = reply["id"].to_s
            next if since && rmodified <= since

            events << {
              "event_id" => "teams:reply:#{mid}:#{rid}",
              "fingerprint" => fingerprint(rmodified, reply.dig("body", "content"), reply["etag"]),
              "event_type" => "teams.reply",
              "resource_id" => "message:#{match[:team]}/#{match[:channel]}/#{rid}",
              "actor_id" => teams_actor_id(reply["from"]),
              "actor_type" => teams_actor_type(reply["from"]),
              "occurred_at" => reply["createdDateTime"].to_s,
              "payload" => {
                "team_id" => match[:team], "channel_id" => match[:channel],
                "message_id" => rid, "reply_to_id" => mid,
                "content" => reply.dig("body", "content"),
                "content_type" => reply.dig("body", "contentType"),
                "last_modified" => rmodified,
                "web_url" => reply["webUrl"]
              }
            }
            watermark = max_time(watermark, rmodified)
          end
        end

        events.sort_by! { |event| event["occurred_at"].to_s }
        watermark ||= utc_iso8601(ctx.clock.now)
        { "events" => events, "cursor" => { "since" => watermark } }
      end

      def handle_reply(input, ctx)
        target = parse_write_target(input["resource_id"].to_s, "reply")
        post_activity(ctx, target, input["body"].to_s, "reply")
      end

      def handle_send_message(input, ctx)
        target = parse_write_target(input["scope"].to_s, "send_message")
        post_activity(ctx, target, input["body"].to_s, "send_message")
      end

      # -- writes (Bot Connector) ------------------------------------------

      def parse_write_target(value, operation)
        if (match = CONVERSATION_PATTERN.match(value))
          return { conversation_id: match[:id], reply_to: match[:activity] }
        end
        if (match = CHANNEL_PATTERN.match(value))
          # A Teams channel id doubles as its channel conversation id.
          return { conversation_id: match[:channel], reply_to: match[:activity] }
        end

        raise InputInvalid.new(plugin: plugin_id, operation: operation,
                               details: ['target must look like "conversation:<id>" or ' \
                                         '"channel:<teamId>/<channelId>"'])
      end

      def post_activity(ctx, target, text, operation)
        service_url, service_host = bot_service(ctx.env)
        token = app_token(ctx, audience: :bot)
        url = "#{service_url}/v3/conversations/#{uri_escape(target[:conversation_id])}/activities"
        activity = { "type" => "message", "text" => text }
        activity["replyToActivityId"] = target[:reply_to] if target[:reply_to]
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
        unless uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty?
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
        unless uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty?
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
          break if url.nil?
          raise InputInvalid.new(plugin: plugin_id, operation: ctx.operation,
                                 details: ["pagination loop detected"]) if seen[url]

          seen[url] = true
          response = ctx.transport.request(method: "GET", url: url, headers: headers, body: nil)
          payload = response.json
          values = payload.is_a?(Hash) ? payload["value"] : nil
          unless values.is_a?(Array)
            raise OutputInvalid.new(plugin: plugin_id, operation: ctx.operation,
                                    details: ["Graph response had an unexpected shape"])
          end
          items.concat(values)

          nxt = payload.is_a?(Hash) ? payload["@odata.nextLink"] : nil
          url = (nxt.nil? || nxt.to_s.empty?) ? nil : begin
            Http.check_host!(nxt.to_s, allowed_hosts)
            nxt.to_s
          end
        end
        items
      end

      # -- helpers ----------------------------------------------------------

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
        since = cursor["since"]
        return nil if since.nil?
        return since if since.is_a?(String) && !since.empty?

        raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                               details: ["cursor.since must be an ISO8601 string"])
      end

      def max_time(current, candidate)
        return candidate if current.nil? || current.empty?
        return current if candidate.nil? || candidate.empty?

        candidate > current ? candidate : current
      end

      def uri_escape(value)
        URI.encode_www_form_component(value.to_s)
      end
    end
  end
end
