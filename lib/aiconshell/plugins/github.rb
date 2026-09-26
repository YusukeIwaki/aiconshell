# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "openssl"
require "time"
require "uri"

module Aiconshell
  module Plugins
    # GitHub App adapter.
    #
    # Auth: GitHub App JWT (RS256) minted from GITHUB_APP_ID +
    # GITHUB_PRIVATE_KEY (or GITHUB_PRIVATE_KEY_FILE), exchanged for an
    # installation token. Polling uses resource APIs (issues, repository
    # issue comments, pull reviews, repository review comments, workflow
    # runs) sorted/filtered by time; it never depends solely on the
    # Events API.
    #
    # Scope: "owner/repo".
    # latest_events cursor: {"since": ISO8601 UTC}.
    # A legacy "next" resume URL is accepted and host-checked before use.
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
      OVERLAP_SECONDS = 60
      CURSOR_KEYS = %w[since next].freeze

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

        cursor = validated_github_cursor(input)
        since_time = cursor_since_time(cursor)
        query_since_time = since_time ? since_time - OVERLAP_SECONDS : nil
        query_since_str = query_since_time&.utc&.iso8601
        threshold_time = query_since_time
        api = api_base(ctx.env)
        allow = [api]
        # Validate a caller-supplied resume URL before any external I/O so a
        # hostile cursor can never cause a credentialed request elsewhere.
        Http.check_host!(cursor["next"].to_s, allow) if cursor["next"]
        token = installation_token(ctx)

        headers = {
          "Authorization" => "Bearer #{token}",
          "Accept" => "application/vnd.github+json",
          "X-GitHub-Api-Version" => API_VERSION
        }

        full = "#{match[:owner]}/#{match[:repo]}"
        collected = []
        watermark_time = since_time

        issues_url = if cursor["next"]
                       resume_url(cursor["next"], allow)
                     else
                       url = "#{api}/repos/#{match[:owner]}/#{match[:repo]}/issues" \
                             "?state=all&sort=updated&direction=asc&per_page=#{PER_PAGE}"
                       url += "&since=#{uri_escape(query_since_str)}" if query_since_str
                       url
                     end

        issues = get_all_pages(ctx, headers, issues_url, allow, MAX_PAGES, what: "issues")
        if issues.length > MAX_EXPANDED_ISSUES
          raise IncompletePoll.new(
            plugin: plugin_id, operation: "latest_events",
            reason: "issues listing exceeded #{MAX_EXPANDED_ISSUES} items; " \
                    "narrow the scope or catch up before retrying"
          )
        end

        issues_map = {}
        pr_numbers = []
        issues.each do |issue|
          number = issue["number"]
          unless number.is_a?(Integer) || number.to_s.match?(/\A\d+\z/)
            raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                    details: ["GitHub issue had no number"])
          end
          number = number.to_i
          is_pr = !issue["pull_request"].nil?
          issues_map[number] = is_pr
          pr_numbers << number if is_pr
        end

        issues.each do |issue|
          number = issue["number"].to_i
          occurred_time = parse_time!(issue["updated_at"], field: "issue updated_at")
          next if threshold_time && occurred_time < threshold_time

          is_pr = issues_map[number]
          kind = is_pr ? "pr" : "issue"
          occurred_str = occurred_time.utc.iso8601
          collected << [occurred_time, {
                          "event_id" => "github:issue:#{full}##{number}",
                          "fingerprint" => fingerprint(occurred_str, issue["title"], issue["body"],
                                                       issue["state"], issue["comments"]),
                          "event_type" => "github.issue",
                          "resource_id" => "#{kind}:#{full}##{number}",
                          "actor_id" => actor_id(issue["user"]),
                          "actor_type" => actor_type(issue["user"]),
                          "occurred_at" => occurred_str,
                          "payload" => {
                            "owner" => match[:owner], "repo" => match[:repo], "number" => number,
                            "title" => issue["title"], "body" => issue["body"].to_s,
                            "state" => issue["state"],
                            "pull_request" => is_pr,
                            "url" => issue["html_url"]
                          }
                        }]
          watermark_time = max_time_obj(watermark_time, occurred_time)
        end

        repo_comments_url = "#{api}/repos/#{full}/issues/comments" \
                            "?sort=updated&direction=asc&per_page=#{PER_PAGE}"
        repo_comments_url += "&since=#{uri_escape(query_since_str)}" if query_since_str
        repo_comments = get_all_pages(ctx, headers, repo_comments_url, allow, MAX_PAGES,
                                      what: "repository issue comments")
        repo_comments.each do |comment|
          occurred_time = parse_time!(comment["updated_at"] || comment["created_at"],
                                      field: "issue comment updated_at")
          next if threshold_time && occurred_time < threshold_time

          comment_id = comment["id"]
          if comment_id.nil? || comment_id.to_s.empty?
            raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                    details: ["GitHub issue comment had no id"])
          end
          number = extract_issue_number(comment)
          is_pr = issues_map.fetch(number) do
            fetch_issue_is_pr(ctx, headers, api, full, number, issues_map)
          end
          kind = is_pr ? "pr" : "issue"
          occurred_str = occurred_time.utc.iso8601
          collected << [occurred_time, {
                          "event_id" => "github:issue_comment:#{comment_id}",
                          "fingerprint" => fingerprint(occurred_str, comment["body"]),
                          "event_type" => "github.issue_comment",
                          "resource_id" => "#{kind}:#{full}##{number}",
                          "actor_id" => actor_id(comment["user"]),
                          "actor_type" => actor_type(comment["user"]),
                          "occurred_at" => occurred_str,
                          "payload" => {
                            "owner" => match[:owner], "repo" => match[:repo], "number" => number,
                            "comment_id" => comment_id, "body" => comment["body"].to_s,
                            "url" => comment["html_url"]
                          }
                        }]
          watermark_time = max_time_obj(watermark_time, occurred_time)
        end

        pr_numbers.uniq.each do |number|
          reviews = get_all_pages(ctx, headers,
                                  "#{api}/repos/#{full}/pulls/#{number}/reviews?per_page=#{PER_PAGE}",
                                  allow, MAX_PAGES, what: "pull reviews")
          reviews.each do |review|
            submitted_raw = review["submitted_at"].to_s
            next if submitted_raw.empty?

            occurred_time = parse_time!(submitted_raw, field: "review submitted_at")
            next if threshold_time && occurred_time < threshold_time

            review_id = review["id"]
            if review_id.nil? || review_id.to_s.empty?
              raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                      details: ["GitHub review had no id"])
            end
            occurred_str = occurred_time.utc.iso8601
            collected << [occurred_time, {
                            "event_id" => "github:review:#{review_id}",
                            "fingerprint" => fingerprint(occurred_str, review["state"], review["body"]),
                            "event_type" => "github.pull_review",
                            "resource_id" => "pr:#{full}##{number}",
                            "actor_id" => actor_id(review["user"]),
                            "actor_type" => actor_type(review["user"]),
                            "occurred_at" => occurred_str,
                            "payload" => {
                              "owner" => match[:owner], "repo" => match[:repo], "number" => number,
                              "review_id" => review_id, "state" => review["state"],
                              "body" => review["body"].to_s,
                              "url" => review["html_url"]
                            }
                          }]
            watermark_time = max_time_obj(watermark_time, occurred_time)
          end
        end

        rcomments_url = "#{api}/repos/#{full}/pulls/comments" \
                        "?sort=updated&direction=asc&per_page=#{PER_PAGE}"
        rcomments_url += "&since=#{uri_escape(query_since_str)}" if query_since_str
        rcomments = get_all_pages(ctx, headers, rcomments_url, allow, MAX_PAGES,
                                  what: "repository review comments")
        rcomments.each do |comment|
          occurred_time = parse_time!(comment["updated_at"] || comment["created_at"],
                                      field: "review comment updated_at")
          next if threshold_time && occurred_time < threshold_time

          comment_id = comment["id"]
          if comment_id.nil? || comment_id.to_s.empty?
            raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                    details: ["GitHub review comment had no id"])
          end
          pr_number = extract_pr_number(comment)
          occurred_str = occurred_time.utc.iso8601
          collected << [occurred_time, {
                          "event_id" => "github:review_comment:#{comment_id}",
                          "fingerprint" => fingerprint(occurred_str, comment["body"], comment["path"]),
                          "event_type" => "github.review_comment",
                          "resource_id" => "pr:#{full}##{pr_number}",
                          "actor_id" => actor_id(comment["user"]),
                          "actor_type" => actor_type(comment["user"]),
                          "occurred_at" => occurred_str,
                          "payload" => {
                            "owner" => match[:owner], "repo" => match[:repo], "number" => pr_number,
                            "comment_id" => comment_id, "path" => comment["path"],
                            "body" => comment["body"].to_s,
                            "url" => comment["html_url"]
                          }
                        }]
          watermark_time = max_time_obj(watermark_time, occurred_time)
        end

        runs_url = "#{api}/repos/#{match[:owner]}/#{match[:repo]}/actions/runs?per_page=#{PER_PAGE}"
        runs = get_all_pages(ctx, headers, runs_url, allow, MAX_WORKFLOW_PAGES,
                             collection: "workflow_runs", what: "workflow runs")
        runs.each do |run|
          occurred_time = parse_time!(run["updated_at"] || run["created_at"],
                                      field: "workflow run updated_at")
          next if threshold_time && occurred_time < threshold_time

          run_id = run["id"]
          if run_id.nil? || run_id.to_s.empty?
            raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                    details: ["GitHub workflow run had no id"])
          end
          occurred_str = occurred_time.utc.iso8601
          collected << [occurred_time, {
                          "event_id" => "github:workflow_run:#{run_id}",
                          "fingerprint" => fingerprint(occurred_str, run["status"],
                                                       run["conclusion"], run["head_sha"]),
                          "event_type" => "github.workflow_run",
                          "resource_id" => "run:#{match[:owner]}/#{match[:repo]}/#{run_id}",
                          "actor_id" => actor_id(run["actor"]),
                          "actor_type" => actor_type(run["actor"]),
                          "occurred_at" => occurred_str,
                          "payload" => {
                            "owner" => match[:owner], "repo" => match[:repo], "run_id" => run_id,
                            "name" => run["name"], "status" => run["status"],
                            "conclusion" => run["conclusion"], "url" => run["html_url"]
                          }
                        }]
          watermark_time = max_time_obj(watermark_time, occurred_time)
        end

        collected.sort_by! { |occurred_time, _| occurred_time.to_f }
        events = collected.map { |_, event| event }
        watermark_time ||= ctx.clock.now.utc
        { "events" => events, "cursor" => { "since" => watermark_time.utc.iso8601 } }
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
        payload = Http.strict_json!(response.body, plugin: plugin_id, operation: "reply")
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
        payload = Http.strict_json!(response.body, plugin: plugin_id, operation: "create_issue")
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
          payload = Http.strict_json!(response.body, plugin: plugin_id, operation: ctx.operation)
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

      # -- polling helpers ------------------------------------------------

      # Follow same-origin Link rel="next" pages. Any page failure raises, so
      # the caller never advances its cursor past an incomplete page. Hitting
      # the page bound with pages remaining raises IncompletePoll without a
      # partial cursor.
      def get_all_pages(ctx, headers, first_url, allowed_hosts, max_pages,
                        collection: nil, what: "listing")
        items = []
        url = first_url
        seen = {}
        max_pages.times do
          break if url.nil?
          raise InputInvalid.new(plugin: plugin_id, operation: ctx.operation,
                                 details: ["pagination loop detected"]) if seen[url]

          seen[url] = true
          response = ctx.transport.request(method: "GET", url: url, headers: headers, body: nil)
          payload = Http.strict_json!(response.body, plugin: plugin_id, operation: ctx.operation)
          page_items = collection ? (payload.is_a?(Hash) ? payload[collection] : nil) : payload
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
        unless url.nil?
          raise IncompletePoll.new(
            plugin: plugin_id, operation: ctx.operation,
            reason: "#{what} pagination exceeded #{max_pages} pages; " \
                    "narrow the scope or catch up before retrying"
          )
        end
        items
      end

      def resume_url(next_url, allowed_hosts)
        Http.check_host!(next_url.to_s, allowed_hosts)
        next_url.to_s
      end

      def validated_github_cursor(input)
        cursor = validated_cursor(input, "latest_events")
        unknown = cursor.keys.map(&:to_s) - CURSOR_KEYS
        unless unknown.empty?
          raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                 details: ["cursor has unsupported keys: #{unknown.join(", ")}"])
        end

        since = cursor["since"]
        unless since.nil?
          unless since.is_a?(String) && !since.empty?
            raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                   details: ["cursor.since must be an ISO8601 string"])
          end
          begin
            Time.iso8601(since)
          rescue ArgumentError
            raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                   details: ["cursor.since must be an ISO8601 string"])
          end
        end

        nxt = cursor["next"]
        unless nxt.nil?
          unless nxt.is_a?(String) && !nxt.empty?
            raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                   details: ["cursor.next must be a URL string"])
          end
          begin
            uri = URI.parse(nxt)
          rescue URI::InvalidURIError
            uri = nil
          end
          unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
            raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                   details: ["cursor.next must be an http(s) URL"])
          end
        end
        cursor
      end

      def cursor_since_time(cursor)
        since = cursor["since"]
        return nil if since.nil?

        Time.iso8601(since).utc
      rescue ArgumentError
        raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                               details: ["cursor.since must be an ISO8601 string"])
      end

      def parse_time!(value, field:)
        raw = value.to_s
        raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                details: ["GitHub response had a missing timestamp for #{field}"]) if raw.empty?

        Time.parse(raw).utc
      rescue ArgumentError
        raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                details: ["GitHub response had an invalid timestamp for #{field}"])
      end

      def max_time_obj(current, candidate)
        return candidate if current.nil?
        return current if candidate.nil?

        candidate > current ? candidate : current
      end

      def extract_issue_number(comment)
        issue_url = comment["issue_url"].to_s.split("?").first.to_s
        match = %r{/repos/[^/]+/[^/]+/issues/(?<number>\d+)\z}.match(issue_url) unless issue_url.empty?
        return match[:number].to_i if match

        html_match = %r{/(issues|pull)/(?<number>\d+)}.match(comment["html_url"].to_s)
        return html_match[:number].to_i if html_match

        raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                details: ["GitHub issue comment had no parent issue number"])
      end

      def extract_pr_number(comment)
        pr_url = comment["pull_request_url"].to_s
        match = %r{/repos/[^/]+/[^/]+/pulls/(?<number>\d+)}.match(pr_url) unless pr_url.empty?
        return match[:number].to_i if match

        html_match = %r{/pull/(?<number>\d+)}.match(comment["html_url"].to_s)
        return html_match[:number].to_i if html_match

        raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                details: ["GitHub review comment had no parent pull number"])
      end

      # Resolve whether a repository-comment parent is an issue or a PR. The
      # issues listing covers recently updated parents; older parents are
      # fetched once and cached so edits on old issues keep canonical
      # issue:/pr: correlation.
      def fetch_issue_is_pr(ctx, headers, api, full, number, cache)
        return cache[number] if cache.key?(number)

        url = "#{api}/repos/#{full}/issues/#{number}"
        response = ctx.transport.request(method: "GET", url: url, headers: headers, body: nil)
        payload = Http.strict_json!(response.body, plugin: plugin_id, operation: ctx.operation)
        unless payload.is_a?(Hash)
          raise OutputInvalid.new(plugin: plugin_id, operation: ctx.operation,
                                  details: ["GitHub issue lookup had an unexpected shape"])
        end
        is_pr = !payload["pull_request"].nil?
        cache[number] = is_pr
        is_pr
      end

      def actor_id(user)
        login = user.is_a?(Hash) ? (user["login"] || user["id"]&.to_s) : nil
        login.nil? || login.to_s.empty? ? "unknown" : login.to_s
      end

      def actor_type(user)
        user.is_a?(Hash) && user["type"].to_s == "Bot" ? "bot" : "human"
      end

      def uri_escape(value)
        URI.encode_www_form_component(value.to_s)
      end
    end
  end
end
