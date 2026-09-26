# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "uri"

module Aiconshell
  module Plugins
    # GitHub App adapter.
    #
    # Auth: GitHub App JWT (RS256) minted from GITHUB_APP_ID +
    # GITHUB_PRIVATE_KEY (or GITHUB_PRIVATE_KEY_FILE), exchanged for an
    # installation token. Polling uses resource APIs (issues, issue comments,
    # pull reviews, review comments, workflow runs) sorted/filtered by time;
    # it never depends solely on the Events API.
    #
    # Scope: "owner/repo".
    # latest_events cursor: {"since": ISO8601, "next": optional resume URL}.
    # Resume/next-link URLs are host-checked before use.
    class Github < Base
      plugin_id "github"
      required_env "GITHUB_APP_ID", "GITHUB_INSTALLATION_ID",
                   "GITHUB_PRIVATE_KEY", "GITHUB_PRIVATE_KEY_FILE"

      operation "latest_events",
                input_schema: Schemas::LATEST_EVENTS_INPUT,
                output_schema: Schemas::LATEST_EVENTS_OUTPUT,
                scope: "github:read"
      operation "reply",
                input_schema: Schemas::REPLY_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "github:write"
      operation "create_issue",
                input_schema: Schemas::CREATE_ISSUE_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "github:write"

      API_URL_DEFAULT = "https://api.github.com"
      API_VERSION = "2022-11-28"
      SCOPE_PATTERN = %r{\A(?<owner>[^/\s]+)/(?<repo>[^/\s]+)\z}
      RESOURCE_PATTERN = %r{\A(?<kind>issue|pr):(?<owner>[^/\s#]+)/(?<repo>[^/\s#]+)#(?<number>\d+)\z}
      MAX_PAGES = 25
      MAX_EXPANDED_ISSUES = 50
      MAX_WORKFLOW_PAGES = 3
      PER_PAGE = 100

      def configured?(env)
        present?(env["GITHUB_APP_ID"]) &&
          present?(env["GITHUB_INSTALLATION_ID"]) &&
          (present?(env["GITHUB_PRIVATE_KEY"]) || present?(env["GITHUB_PRIVATE_KEY_FILE"]))
      end

      private

      def handle_latest_events(input, ctx)
        match = SCOPE_PATTERN.match(input["scope"].to_s)
        unless match
          raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                 details: ['scope must look like "owner/repo"'])
        end

        cursor = validated_cursor(input, "latest_events")
        since = cursor_since(cursor)
        api = api_base(ctx.env)
        allow = [URI.parse(api).host.to_s.downcase]
        # Validate a caller-supplied resume URL before any external I/O so a
        # hostile cursor can never cause a credentialed request elsewhere.
        Http.check_host!(cursor["next"].to_s, allow) if cursor["next"]
        token = installation_token(ctx)

        headers = {
          "Authorization" => "Bearer #{token}",
          "Accept" => "application/vnd.github+json",
          "X-GitHub-Api-Version" => API_VERSION
        }

        events = []
        watermark = since

        issues_url = if cursor["next"]
                       resume_url(cursor["next"], allow)
                     else
                       url = "#{api}/repos/#{match[:owner]}/#{match[:repo]}/issues" \
                             "?state=all&sort=updated&direction=asc&per_page=#{PER_PAGE}"
                       url += "&since=#{uri_escape(since)}" if since
                       url
                     end

        issues = get_all_pages(ctx, headers, issues_url, allow, MAX_PAGES)
        issues.first(MAX_EXPANDED_ISSUES).each do |issue|
          updated = issue["updated_at"].to_s
          next if since && updated <= since

          number = issue["number"]
          full = "#{match[:owner]}/#{match[:repo]}"
          events << {
            "event_id" => "github:issue:#{full}##{number}",
            "fingerprint" => fingerprint(updated, issue["title"], issue["body"],
                                         issue["state"], issue["comments"]),
            "event_type" => "github.issue",
            "resource_id" => "issue:#{full}##{number}",
            "actor_id" => actor_id(issue["user"]),
            "actor_type" => actor_type(issue["user"]),
            "occurred_at" => updated,
            "payload" => {
              "owner" => match[:owner], "repo" => match[:repo], "number" => number,
              "title" => issue["title"], "state" => issue["state"],
              "pull_request" => !issue["pull_request"].nil?,
              "url" => issue["html_url"]
            }
          }
          watermark = max_time(watermark, updated)

          comments_url = "#{api}/repos/#{full}/issues/#{number}/comments?per_page=#{PER_PAGE}"
          comments_url += "&since=#{uri_escape(since)}" if since
          get_all_pages(ctx, headers, comments_url, allow, MAX_PAGES).each do |comment|
            cu = comment["updated_at"].to_s
            next if since && cu <= since

            events << {
              "event_id" => "github:issue_comment:#{comment["id"]}",
              "fingerprint" => fingerprint(cu, comment["body"]),
              "event_type" => "github.issue_comment",
              "resource_id" => "issue:#{full}##{number}",
              "actor_id" => actor_id(comment["user"]),
              "actor_type" => actor_type(comment["user"]),
              "occurred_at" => cu,
              "payload" => {
                "owner" => match[:owner], "repo" => match[:repo], "number" => number,
                "comment_id" => comment["id"], "url" => comment["html_url"]
              }
            }
            watermark = max_time(watermark, cu)
          end

          next unless issue["pull_request"]

          pr_prefix = "#{api}/repos/#{full}/pulls/#{number}"
          get_all_pages(ctx, headers, "#{pr_prefix}/reviews?per_page=#{PER_PAGE}",
                        allow, MAX_PAGES).each do |review|
            submitted = review["submitted_at"].to_s
            next if submitted.empty?
            next if since && submitted <= since

            events << {
              "event_id" => "github:review:#{review["id"]}",
              "fingerprint" => fingerprint(submitted, review["state"], review["body"]),
              "event_type" => "github.pull_review",
              "resource_id" => "pr:#{full}##{number}",
              "actor_id" => actor_id(review["user"]),
              "actor_type" => actor_type(review["user"]),
              "occurred_at" => submitted,
              "payload" => {
                "owner" => match[:owner], "repo" => match[:repo], "number" => number,
                "review_id" => review["id"], "state" => review["state"],
                "url" => review["html_url"]
              }
            }
            watermark = max_time(watermark, submitted)
          end

          rcomments_url = "#{pr_prefix}/comments?sort=updated&direction=asc&per_page=#{PER_PAGE}"
          rcomments_url += "&since=#{uri_escape(since)}" if since
          get_all_pages(ctx, headers, rcomments_url, allow, MAX_PAGES).each do |comment|
            cu = comment["updated_at"].to_s
            next if since && cu <= since

            events << {
              "event_id" => "github:review_comment:#{comment["id"]}",
              "fingerprint" => fingerprint(cu, comment["body"], comment["path"]),
              "event_type" => "github.review_comment",
              "resource_id" => "pr:#{full}##{number}",
              "actor_id" => actor_id(comment["user"]),
              "actor_type" => actor_type(comment["user"]),
              "occurred_at" => cu,
              "payload" => {
                "owner" => match[:owner], "repo" => match[:repo], "number" => number,
                "comment_id" => comment["id"], "path" => comment["path"],
                "url" => comment["html_url"]
              }
            }
            watermark = max_time(watermark, cu)
          end
        end

        runs_url = "#{api}/repos/#{match[:owner]}/#{match[:repo]}/actions/runs?per_page=#{PER_PAGE}"
        get_all_pages(ctx, headers, runs_url, allow, MAX_WORKFLOW_PAGES, collection: "workflow_runs").each do |run|
          ru = run["updated_at"].to_s
          next if since && ru <= since

          events << {
            "event_id" => "github:workflow_run:#{run["id"]}",
            "fingerprint" => fingerprint(ru, run["status"], run["conclusion"], run["head_sha"]),
            "event_type" => "github.workflow_run",
            "resource_id" => "run:#{match[:owner]}/#{match[:repo]}/#{run["id"]}",
            "actor_id" => actor_id(run["actor"]),
            "actor_type" => actor_type(run["actor"]),
            "occurred_at" => ru,
            "payload" => {
              "owner" => match[:owner], "repo" => match[:repo], "run_id" => run["id"],
              "name" => run["name"], "status" => run["status"],
              "conclusion" => run["conclusion"], "url" => run["html_url"]
            }
          }
          watermark = max_time(watermark, ru)
        end

        events.sort_by! { |event| event["occurred_at"].to_s }
        watermark ||= utc_iso8601(ctx.clock.now)
        { "events" => events, "cursor" => { "since" => watermark } }
      end

      def handle_reply(input, ctx)
        match = RESOURCE_PATTERN.match(input["resource_id"].to_s)
        unless match
          raise InputInvalid.new(plugin: plugin_id, operation: "reply",
                                 details: ['resource_id must look like "issue:owner/repo#123" ' \
                                           'or "pr:owner/repo#123"'])
        end

        api = api_base(ctx.env)
        token = installation_token(ctx)
        url = "#{api}/repos/#{match[:owner]}/#{match[:repo]}/issues/#{match[:number]}/comments"
        response = ctx.transport.request(
          method: "POST", url: url, headers: write_headers(token),
          body: JSON.generate({ "body" => input["body"] })
        )
        payload = response.json
        unless payload.is_a?(Hash) && payload["id"]
          raise OutputInvalid.new(plugin: plugin_id, operation: "reply",
                                  details: ["GitHub response did not include a comment id"])
        end

        { "external_id" => payload["id"].to_s, "url" => payload["html_url"] }
      end

      def handle_create_issue(input, ctx)
        match = SCOPE_PATTERN.match(input["scope"].to_s)
        unless match
          raise InputInvalid.new(plugin: plugin_id, operation: "create_issue",
                                 details: ['scope must look like "owner/repo"'])
        end

        api = api_base(ctx.env)
        token = installation_token(ctx)
        url = "#{api}/repos/#{match[:owner]}/#{match[:repo]}/issues"
        response = ctx.transport.request(
          method: "POST", url: url, headers: write_headers(token),
          body: JSON.generate({ "title" => input["title"], "body" => input["body"] })
        )
        payload = response.json
        unless payload.is_a?(Hash) && payload["number"]
          raise OutputInvalid.new(plugin: plugin_id, operation: "create_issue",
                                  details: ["GitHub response did not include an issue number"])
        end

        { "external_id" => payload["number"].to_s, "url" => payload["html_url"] }
      end

      # -- auth -----------------------------------------------------------

      def api_base(env)
        raw = env["GITHUB_API_URL"]
        raw = API_URL_DEFAULT if raw.nil? || raw.to_s.strip.empty?
        uri = URI.parse(raw.to_s.strip.chomp("/"))
        unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
          raise CredentialsMissing.new(plugin: plugin_id,
                                       missing: ["GITHUB_API_URL (must be an http(s) URL)"])
        end
        "#{uri.scheme}://#{uri.host}#{":#{uri.port}" if uri.port != uri.default_port}#{uri.path}"
      rescue URI::InvalidURIError
        raise CredentialsMissing.new(plugin: plugin_id,
                                     missing: ["GITHUB_API_URL (must be an http(s) URL)"])
      end

      # Short-lived installation token, cached in memory until shortly before
      # expiry. The cache key includes the credential identity so tests or
      # credential rotation never reuse a token minted for other credentials.
      def installation_token(ctx)
        env = ctx.env
        missing = []
        missing << "GITHUB_APP_ID" unless present?(env["GITHUB_APP_ID"])
        missing << "GITHUB_INSTALLATION_ID" unless present?(env["GITHUB_INSTALLATION_ID"])
        key = secret_from(env, "GITHUB_PRIVATE_KEY", "GITHUB_PRIVATE_KEY_FILE")
        missing << "GITHUB_PRIVATE_KEY or GITHUB_PRIVATE_KEY_FILE" if key.nil? || key.empty?
        require_credentials!(missing)

        cache_key = [env["GITHUB_APP_ID"].to_s, env["GITHUB_INSTALLATION_ID"].to_s,
                     Digest::SHA256.hexdigest(key)]
        @token_mutex ||= Mutex.new
        @token_mutex.synchronize do
          cached = @token_cache
          if cached && cached[:key] == cache_key && cached[:expires_at] > ctx.clock.now
            return cached[:token]
          end

          jwt = app_jwt(env["GITHUB_APP_ID"].to_s, key, ctx.clock)
          url = "#{api_base(env)}/app/installations/#{env["GITHUB_INSTALLATION_ID"]}/access_tokens"
          response = ctx.transport.request(
            method: "POST", url: url,
            headers: {
              "Authorization" => "Bearer #{jwt}",
              "Accept" => "application/vnd.github+json",
              "X-GitHub-Api-Version" => API_VERSION
            },
            body: ""
          )
          payload = response.json
          unless payload.is_a?(Hash) && payload["token"] && payload["expires_at"]
            raise OutputInvalid.new(plugin: plugin_id, operation: ctx.operation,
                                    details: ["GitHub token response had an unexpected shape"])
          end

          expires_at = Time.parse(payload["expires_at"].to_s) - 60
          @token_cache = { key: cache_key, token: payload["token"].to_s, expires_at: expires_at }
          @token_cache[:token]
        end
      end

      # Minimal RS256 JWT for GitHub App authentication (stdlib only).
      def app_jwt(app_id, key_pem, clock)
        now = clock.now.to_i
        signing_input = "#{b64url(JSON.generate({ "alg" => "RS256", "typ" => "JWT" }))}." \
                        "#{b64url(JSON.generate({ "iat" => now - 60, "exp" => now + 540, "iss" => app_id }))}"
        key = OpenSSL::PKey::RSA.new(key_pem)
        signature = key.sign(OpenSSL::Digest::SHA256.new, signing_input)
        "#{signing_input}.#{b64url(signature)}"
      rescue OpenSSL::PKey::PKeyError, OpenSSL::OpenSSLError
        raise CredentialsMissing.new(plugin: plugin_id,
                                     missing: ["GITHUB_PRIVATE_KEY (unparsable PEM)"])
      end

      def b64url(bytes)
        Base64.urlsafe_encode64(bytes.to_s, padding: false)
      end

      def write_headers(token)
        {
          "Authorization" => "Bearer #{token}",
          "Accept" => "application/vnd.github+json",
          "X-GitHub-Api-Version" => API_VERSION,
          "Content-Type" => "application/json"
        }
      end

      # -- paging ---------------------------------------------------------

      # Follow same-host Link rel="next" pages. Any page failure raises, so the
      # caller never advances its cursor past an incomplete page.
      def get_all_pages(ctx, headers, first_url, allowed_hosts, max_pages, collection: nil)
        items = []
        url = first_url
        seen = {}
        max_pages.times do
          break if url.nil?
          raise InputInvalid.new(plugin: plugin_id, operation: ctx.operation,
                                 details: ["pagination loop detected"]) if seen[url]

          seen[url] = true
          response = ctx.transport.request(method: "GET", url: url, headers: headers, body: nil)
          payload = response.json
          page_items = collection ? payload&.fetch(collection, nil) : payload
          unless page_items.is_a?(Array)
            raise OutputInvalid.new(plugin: plugin_id, operation: ctx.operation,
                                    details: ["GitHub response for #{ctx.operation} had an unexpected shape"])
          end
          items.concat(page_items)

          nxt = Http.next_link(response.headers)
          url = nxt.nil? ? nil : begin
            Http.check_host!(nxt, allowed_hosts)
            nxt
          end
        end
        items
      end

      def resume_url(next_url, allowed_hosts)
        Http.check_host!(next_url.to_s, allowed_hosts)
        next_url.to_s
      end

      def cursor_since(cursor)
        since = cursor["since"]
        return nil if since.nil?
        return since if since.is_a?(String) && !since.empty?

        raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                               details: ["cursor.since must be an ISO8601 string"])
      end

      def actor_id(user)
        login = user.is_a?(Hash) ? (user["login"] || user["id"]&.to_s) : nil
        login.nil? || login.to_s.empty? ? "unknown" : login.to_s
      end

      def actor_type(user)
        user.is_a?(Hash) && user["type"].to_s == "Bot" ? "bot" : "human"
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
