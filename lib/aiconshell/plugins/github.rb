# frozen_string_literal: true

require "base64"
require "date"
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
    # runs) with bounded reconciliation; it never depends solely on the
    # Events API.
    #
    # Scope: "owner/repo".
    # Version-2 cursors retain a fixed optional since floor and independent
    # bounded sweep positions. Every poll checks the head of every stream.
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
      SCOPE_PATTERN = %r{\A(?<owner>[A-Za-z0-9_-]+)/(?<repo>[A-Za-z0-9_.-]+)\z}
      RESOURCE_PATTERN = %r{\A(?<kind>issue|pr):(?<owner>[^/\s#]+)/(?<repo>[^/\s#]+)#(?<number>\d+)\z}
      MAX_PAGES = 25
      PER_PAGE = 100
      ISSUE_PAGE_SIZE = 25
      STREAM_PAGE_BUDGET = 2
      WORKFLOW_PAGE_BUDGET = 3
      OVERLAP_SECONDS = 60
      STREAM_NAMES = %w[issues issue_comments review_comments workflow_runs].freeze
      TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):?[0-5]\d)\z/

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

        full = "#{match[:owner]}/#{match[:repo]}"
        api = api_base(ctx.env)
        allow = [api]
        cursor = validated_github_cursor(input, full, api)
        since_time = cursor["since"] && strict_time(cursor["since"])
        query_since_time = since_time ? since_time - OVERLAP_SECONDS : nil
        threshold_time = query_since_time
        urls = stream_urls(api, full, since_time)
        token = installation_token(ctx)

        headers = {
          "Authorization" => "Bearer #{token}",
          "Accept" => "application/vnd.github+json",
          "X-GitHub-Api-Version" => API_VERSION
        }

        collected = []
        next_streams = {}
        issues, next_streams["issues"] = reconciliation_pages(
          ctx, headers, urls["issues"], allow, cursor["streams"]["issues"],
          page_size: ISSUE_PAGE_SIZE, page_budget: STREAM_PAGE_BUDGET
        )

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
                          # Comments update their parent's timestamp/count, but
                          # must not turn our own reply into a new author event.
                          "fingerprint" => fingerprint(issue["title"], issue["body"], issue["state"]),
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
        end

        repo_comments, next_streams["issue_comments"] = reconciliation_pages(
          ctx, headers, urls["issue_comments"], allow, cursor["streams"]["issue_comments"],
          page_size: PER_PAGE, page_budget: STREAM_PAGE_BUDGET
        )
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
        end

        pr_numbers.uniq.each do |number|
          reviews = get_all_pages(ctx, headers,
                                  "#{api}/repos/#{full}/pulls/#{number}/reviews?per_page=#{PER_PAGE}",
                                  allow, MAX_PAGES, what: "pull reviews")
          reviews.each do |review|
            submitted_raw = review["submitted_at"].to_s
            next if submitted_raw.empty?

            occurred_time = parse_time!(submitted_raw, field: "review submitted_at")
            # Reviews expose submitted_at, not an edit timestamp. Reconcile
            # all reviews of each observed PR so edits retain their fingerprint.

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
          end
        end

        rcomments, next_streams["review_comments"] = reconciliation_pages(
          ctx, headers, urls["review_comments"], allow, cursor["streams"]["review_comments"],
          page_size: PER_PAGE, page_budget: STREAM_PAGE_BUDGET
        )
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
        end

        runs, next_streams["workflow_runs"] = reconciliation_pages(
          ctx, headers, urls["workflow_runs"], allow, cursor["streams"]["workflow_runs"],
          page_size: PER_PAGE, page_budget: WORKFLOW_PAGE_BUDGET, collection: "workflow_runs"
        )
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
                                                       run["conclusion"], run["head_sha"], run["run_attempt"]),
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
        end

        collected.uniq! { |_, event| [event["event_id"], event["fingerprint"]] }
        collected.sort_by! { |occurred_time, _| occurred_time.to_f }
        events = collected.map { |_, event| event }
        { "events" => events, "cursor" => {
          "version" => 2, "scope" => full, "since" => since_time&.iso8601,
          "streams" => next_streams
        } }
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
        unless uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty? &&
               uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
          raise CredentialsMissing.new(plugin: plugin_id,
                                       missing: ["GITHUB_API_URL (must be an https URL without userinfo, query, or fragment)"])
        end
        "#{uri.scheme}://#{uri.host}#{":#{uri.port}" if uri.port != uri.default_port}#{uri.path}"
      rescue URI::InvalidURIError
        raise CredentialsMissing.new(plugin: plugin_id,
                                     missing: ["GITHUB_API_URL (must be an https URL without userinfo, query, or fragment)"])
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

      def stream_urls(api, full, since_time)
        since_query = since_time ? "&since=#{uri_escape((since_time - OVERLAP_SECONDS).iso8601)}" : ""
        prefix = "#{api}/repos/#{full}"
        {
          # Reviews lack an edit timestamp, so discover even PRs whose parent
          # predates the initial floor; filter issue snapshots client-side.
          "issues" => "#{prefix}/issues?state=all&sort=updated&direction=desc&per_page=#{ISSUE_PAGE_SIZE}",
          "issue_comments" => "#{prefix}/issues/comments?sort=updated&direction=desc&per_page=#{PER_PAGE}#{since_query}",
          "review_comments" => "#{prefix}/pulls/comments?sort=updated&direction=desc&per_page=#{PER_PAGE}#{since_query}",
          "workflow_runs" => "#{prefix}/actions/runs?per_page=#{PER_PAGE}"
        }
      end

      # Check the live head on every call, then continue the persisted sweep.
      # A bounded result is complete for these pages, not for the repository.
      # The fixed since floor and the next URL preserve unvisited history;
      # a later whole sweep reconciles movement in GitHub's offset pagination.
      def reconciliation_pages(ctx, headers, first_url, allowed_hosts, state,
                               page_size:, page_budget:, collection: nil)
        items, head_next = read_page(ctx, headers, first_url, first_url, allowed_hosts,
                                    page_size: page_size, collection: collection)
        url = head_next && (state["next"] || head_next)
        (page_budget - 1).times do
          break unless url

          page_items, url = read_page(ctx, headers, url, first_url, allowed_hosts,
                                     page_size: page_size, collection: collection)
          items.concat(page_items)
        end
        [items, { "next" => url,
                  "completed_at" => url ? state["completed_at"] : ctx.clock.now.utc.iso8601 }]
      end

      def read_page(ctx, headers, url, first_url, allowed_hosts, page_size:, collection: nil)
        response = ctx.transport.request(method: "GET", url: url, headers: headers, body: nil)
        payload = Http.strict_json!(response.body, plugin: plugin_id, operation: ctx.operation)
        items = collection ? (payload.is_a?(Hash) ? payload[collection] : nil) : payload
        unless items.is_a?(Array) && items.length <= page_size && items.all? { |item| item.is_a?(Hash) }
          raise OutputInvalid.new(plugin: plugin_id, operation: ctx.operation,
                                  details: ["GitHub listing did not match its requested page shape or size"])
        end
        nxt = Http.next_link(response.headers)
        if nxt
          nxt = validate_page_url!(nxt, first_url, allowed_hosts)
          current_page = URI.decode_www_form(URI.parse(url).query.to_s).to_h.fetch("page", "1").to_i
          next_page = URI.decode_www_form(URI.parse(nxt).query.to_s).to_h.fetch("page").to_i
          unless next_page == current_page + 1
            raise OutputInvalid.new(plugin: plugin_id, operation: ctx.operation,
                                    details: ["GitHub pagination did not advance to the next page"])
          end
        end
        [items, nxt]
      end

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
          page_items, url = read_page(ctx, headers, url, first_url, allowed_hosts,
                                      page_size: PER_PAGE, collection: collection)
          items.concat(page_items)
        end
        unless url.nil?
          raise IncompletePoll.new(
            plugin: plugin_id, operation: ctx.operation,
            reason: "#{what} pagination exceeded #{max_pages} pages; " \
                    "this PR requires resumable review paging before polling can continue"
          )
        end
        items
      end

      def validate_page_url!(url, first_url, allowed_hosts, from_cursor: false)
        error = from_cursor ? InputInvalid : OutputInvalid
        unless url.is_a?(String) && !url.empty?
          raise error.new(plugin: plugin_id, operation: "latest_events",
                          details: ["cursor pagination URL must be a nonempty string"])
        end
        uri = Http.check_host!(url, allowed_hosts)
        expected = URI.parse(first_url)
        pairs = URI.decode_www_form(uri.query.to_s)
        query = pairs.to_h
        page = query.delete("page")
        path_matches = uri.path.casecmp?(expected.path) ||
                       (!from_cursor && repository_id_path?(uri.path, expected.path))
        valid = uri.fragment.nil? && path_matches &&
                pairs.map(&:first).uniq.length == pairs.length &&
                query == URI.decode_www_form(expected.query.to_s).to_h &&
                page.is_a?(String) && page.match?(/\A[1-9]\d*\z/) && page.to_i >= 2
        unless valid
          raise error.new(plugin: plugin_id, operation: "latest_events",
                          details: ["cursor pagination URL must match its repository, stream, filters, and page size"])
        end
        # GitHub can advertise /repositories/{id}/... in its Link header.
        # Use it only as a page-number hint; requests and durable checkpoints
        # remain bound to the caller's named repository and exact endpoint.
        "#{first_url}&page=#{page}"
      rescue ArgumentError
        raise error.new(plugin: plugin_id, operation: "latest_events",
                        details: ["cursor pagination URL has invalid parameters"])
      end

      def repository_id_path?(actual, expected)
        match = %r{\A(.*)/repos/[^/]+/[^/]+(/.+)\z}.match(expected)
        match && actual.match?(%r{\A#{Regexp.escape(match[1])}/repositories/[1-9]\d*#{Regexp.escape(match[2])}\z}i)
      end

      def validated_github_cursor(input, full, api)
        cursor = validated_cursor(input, "latest_events")
        if cursor.key?("version")
          unless cursor["version"] == 2 && cursor["scope"] == full &&
                 (cursor.keys - %w[version scope since streams]).empty? &&
                 cursor["streams"].is_a?(Hash) && cursor["streams"].keys.sort == STREAM_NAMES.sort
            invalid_cursor!("cursor must be version 2 for this repository and contain all stream states")
          end
        elsif (cursor.keys - ["since"]).any?
          invalid_cursor!("cursor only accepts legacy since or version 2 stream states; legacy next is unsupported")
        end

        since = cursor["since"]
        since_time = since.nil? ? nil : strict_time(since)
        urls = stream_urls(api, full, since_time)
        states = cursor["streams"] || STREAM_NAMES.to_h { |name| [name, { "next" => nil, "completed_at" => nil }] }
        states.each do |name, state|
          unless state.is_a?(Hash) && state.keys.sort == %w[completed_at next]
            invalid_cursor!("cursor stream must contain next and completed_at")
          end
          strict_time(state["completed_at"]) unless state["completed_at"].nil?
          validate_page_url!(state["next"], urls.fetch(name), [api], from_cursor: true) unless state["next"].nil?
        end
        { "since" => since_time&.iso8601, "streams" => states }
      rescue ArgumentError
        invalid_cursor!("cursor timestamps must be valid ISO8601 strings with a timezone")
      end

      def invalid_cursor!(reason)
        raise InputInvalid.new(plugin: plugin_id, operation: "latest_events", details: [reason])
      end

      def strict_time(value)
        raise ArgumentError unless value.is_a?(String) && TIMESTAMP_PATTERN.match?(value)

        Date.iso8601(value[0, 10])
        Time.iso8601(value).utc
      end

      def parse_time!(value, field:)
        raw = value.to_s
        raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                details: ["GitHub response had a missing timestamp for #{field}"]) if raw.empty?

        strict_time(raw)
      rescue ArgumentError
        raise OutputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                details: ["GitHub response had an invalid timestamp for #{field}"])
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
