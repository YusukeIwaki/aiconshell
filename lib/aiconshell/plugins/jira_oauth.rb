# frozen_string_literal: true

require_relative "base"
require_relative "errors"
require_relative "schemas"
require_relative "http"
require_relative "jira"
require_relative "../oauth/errors"
require_relative "../oauth/binding"
require_relative "../oauth/config"
require_relative "../oauth/atlassian"

module Aiconshell
  module Plugins
    # Jira Cloud adapter acting as the OAuth-consented user (delegated).
    #
    # Same issue/comment/changelog shape as the service-account `jira`
    # adapter, but every request uses the trusted OAuth binding's verified
    # cloud (`https://api.atlassian.com/ex/jira/<cloudId>/rest/api/3/...`)
    # with a just-in-time Bearer token. The cloud, principal, and actor are
    # never taken from AI/input/env, `*` scopes are out of scope, and no
    # service-account (JIRA_*) fallback exists.
    #
    # Timezone independence: unlike `jira` (which needs the service
    # account's Jira timezone set to UTC because JQL datetimes are
    # evaluated in the account timezone), this adapter sends no
    # time predicate in JQL. It pages the whole project (bounded) and
    # filters by ISO8601 instants in Ruby, so the consenting user's
    # timezone setting is never read or changed.
    #
    # Trusted context keys (application-built, never input JSON):
    #   "oauth_binding" (Aiconshell::Oauth::Binding or its to_h) and
    #   "oauth_credential_provider" (binding_for/access_token ports).
    # The same binding is resolved once per invoke; the adapter never
    # calls binding_for to switch users and never retries writes on 401.
    class JiraOauth < Jira
      # Strict receipt shapes: server ids/keys are never coerced with to_s.
      COMMENT_ID_PATTERN = /\A\d+\z/
      ISSUE_KEY_PATTERN = /\A[A-Z][A-Z0-9_]*-\d+\z/
      # nextPage query allowlist: only paging elements may change across
      # pages. Path must equal the requesting collection path exactly.
      ALLOWED_NEXT_QUERY_KEYS = %w[startAt maxResults orderBy].freeze

      plugin_id "jira_oauth"
      required_env "OAUTH_ATLASSIAN_CLIENT_ID", "OAUTH_ATLASSIAN_CLIENT_SECRET",
                   "OAUTH_ATLASSIAN_CLIENT_SECRET_FILE", "OAUTH_ATLASSIAN_CLOUD_ID",
                   "OAUTH_ATLASSIAN_REDIRECT_URI"

      operation "latest_events",
                input_schema: Schemas::LATEST_EVENTS_INPUT,
                output_schema: Schemas::LATEST_EVENTS_OUTPUT,
                scope: "jira_oauth:read",
                read_only: true
      operation "reply",
                input_schema: Schemas::REPLY_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "jira_oauth:write"
      operation "create_issue",
                input_schema: Schemas::CREATE_ISSUE_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "jira_oauth:write"

      # Optional test seam. The trusted context provider wins when both
      # are present; this default only lets standalone tests inject a
      # fake without touching the shared Registry.
      def initialize(credential_provider: nil)
        @injected_provider = credential_provider
      end

      def configured?(env)
        Aiconshell::Oauth::Config.new(env: env).missing_env_names("atlassian").empty?
      end

      def validate_operation_input(op, input)
        super
        return unless op.name == "latest_events" && input["scope"].to_s == "*"

        raise InputInvalid.new(
          plugin: plugin_id, operation: op.name,
          details: ['scope "*" is not supported by jira_oauth; use a concrete project key like "PROJ"']
        )
      end

      def inspect
        "#<Aiconshell::Plugins::JiraOauth>"
      end

      def to_s
        inspect
      end

      private

      def handle_latest_events(input, ctx)
        scope = input["scope"].to_s
        if scope == "*"
          raise InputInvalid.new(
            plugin: plugin_id, operation: "latest_events",
            details: ['scope "*" is not supported by jira_oauth; use a concrete project key like "PROJ"']
          )
        end
        unless PROJECT_PATTERN.match?(scope)
          raise InputInvalid.new(
            plugin: plugin_id, operation: "latest_events",
            details: ['scope must be a Jira project key like "PROJ"']
          )
        end

        cursor = validated_cursor(input, "latest_events")
        since = cursor_since(cursor)
        cutoff = since && since - OVERLAP_SECONDS

        oauth = resolve_oauth(ctx)
        base = oauth[:base]
        headers = bearer_headers(oauth[:token])

        # No time predicate: JQL datetimes follow the consenting user's
        # timezone, so filter by instant in Ruby instead.
        jql = "project = #{scope} ORDER BY updated ASC"
        issues = search_issues(ctx, headers, base, jql)

        events = []
        watermark = since
        seen_issues = {}
        issues.each do |issue|
          unless issue.is_a?(Hash) && RESOURCE_PATTERN.match?("issue:#{issue["key"]}") &&
                 issue["fields"].is_a?(Hash)
            invalid_output!("Jira issue response had an unexpected shape")
          end
          version = [issue["key"], issue.dig("fields", "updated")]
          next if seen_issues[version]

          seen_issues[version] = true
          watermark = emit_issue_events(ctx, headers, base, issue, cutoff, watermark, events)
        end

        events.uniq! { |event| [event["event_id"], event["fingerprint"]] }
        events.sort_by! { |event| parse_timestamp(event["occurred_at"]) }
        watermark ||= ctx.clock.now
        { "events" => events, "cursor" => { "since" => timestamp_string(watermark) } }
      end

      def handle_reply(input, ctx)
        match = RESOURCE_PATTERN.match(input["resource_id"].to_s)
        unless match
          raise InputInvalid.new(plugin: plugin_id, operation: "reply",
                                 details: ['resource_id must look like "issue:PROJ-123"'])
        end

        oauth = resolve_oauth(ctx)
        base = oauth[:base]
        headers = bearer_headers(oauth[:token])
        response = ctx.transport.request(
          method: "POST",
          url: "#{base}/rest/api/3/issue/#{uri_escape(match[:key])}/comment",
          headers: post_headers(headers),
          body: JSON.generate({ "body" => adf_doc(input["body"].to_s) })
        )
        payload = response.json
        comment_id = payload.is_a?(Hash) ? payload["id"] : nil
        unless comment_id.is_a?(String) && COMMENT_ID_PATTERN.match?(comment_id)
          raise OutputInvalid.new(plugin: plugin_id, operation: "reply",
                                  details: ["Jira response did not include a comment id"])
        end

        { "external_id" => comment_id, "url" => browse_url(base, match[:key]) }
      end

      def handle_create_issue(input, ctx)
        scope = input["scope"].to_s
        unless PROJECT_PATTERN.match?(scope)
          raise InputInvalid.new(plugin: plugin_id, operation: "create_issue",
                                 details: ['scope must be a Jira project key like "PROJ"'])
        end

        oauth = resolve_oauth(ctx)
        base = oauth[:base]
        headers = bearer_headers(oauth[:token])
        response = ctx.transport.request(
          method: "POST", url: "#{base}/rest/api/3/issue",
          headers: post_headers(headers),
          body: JSON.generate({
                                "fields" => {
                                  "project" => { "key" => scope },
                                  "summary" => input["title"],
                                  "description" => adf_doc(input["body"].to_s),
                                  "issuetype" => { "name" => "Task" }
                                }
                              })
        )
        payload = response.json
        issue_key = payload.is_a?(Hash) ? payload["key"] : nil
        unless issue_key.is_a?(String) && ISSUE_KEY_PATTERN.match?(issue_key) &&
               issue_key.start_with?("#{scope}-")
          raise OutputInvalid.new(plugin: plugin_id, operation: "create_issue",
                                  details: ["Jira response did not include an issue key"])
        end

        { "external_id" => issue_key, "url" => browse_url(base, issue_key) }
      end

      # Never fall back to service-account env: these overrides fail
      # closed if legacy helpers are ever reached.
      def base_url(_env)
        raise CredentialsMissing.new(plugin: plugin_id, missing: ["oauth_binding"])
      end

      def auth_headers(_env)
        raise CredentialsMissing.new(plugin: plugin_id, missing: ["oauth_credential_provider"])
      end

      def bearer_headers(token)
        { "Authorization" => "Bearer #{token}", "Accept" => "application/json" }
      end

      # Fixed-generation credential: the application-supplied binding is
      # resolved exactly once per invoke and reused for every paged call.
      # binding_for is never called here, so the current user is never
      # re-selected and service-account env is never consulted.
      def resolve_oauth(ctx)
        ctx_hash = ctx.context.is_a?(Hash) ? ctx.context : {}
        binding_raw = ctx_hash["oauth_binding"] || ctx_hash[:oauth_binding]
        provider = ctx_hash["oauth_credential_provider"] || ctx_hash[:oauth_credential_provider] ||
                   @injected_provider

        if binding_raw.nil?
          raise CredentialsMissing.new(plugin: plugin_id, missing: ["oauth_binding"])
        end
        if provider.nil?
          raise CredentialsMissing.new(plugin: plugin_id, missing: ["oauth_credential_provider"])
        end
        unless provider.respond_to?(:access_token)
          raise CredentialsMissing.new(plugin: plugin_id, missing: ["oauth_credential_provider"])
        end

        binding = Aiconshell::Oauth::Binding.from_h(binding_raw)
        unless binding.provider.to_s == "atlassian"
          raise CredentialsMissing.new(plugin: plugin_id, missing: ["oauth_binding provider"])
        end
        cloud = binding.cloud.to_s
        pattern = Aiconshell::Oauth::Atlassian::CLOUD_ID_PATTERN
        if cloud.empty? || !pattern.match?(cloud)
          raise CredentialsMissing.new(plugin: plugin_id, missing: ["oauth_binding cloud"])
        end
        if binding.principal.to_s.empty?
          raise CredentialsMissing.new(plugin: plugin_id, missing: ["oauth_binding principal"])
        end
        if binding.connection_id.nil?
          raise CredentialsMissing.new(plugin: plugin_id, missing: ["oauth_binding"])
        end

        # Let OAuth typed errors (NotConnected/BindingMismatch/ProviderError/
        # RefreshBusy) propagate unchanged: they carry safe codes only and
        # are raised before any Jira HTTP call in this invoke.
        token = provider.access_token(binding)
        unless token.is_a?(String) && !token.empty?
          raise OutputInvalid.new(plugin: plugin_id, operation: ctx.operation,
                                  details: ["OAuth provider returned an unexpected token shape"])
        end

        host = Aiconshell::Oauth::Config::ATLASSIAN_JIRA_API_HOST
        { binding: binding, token: token, cloud: cloud, base: "https://#{host}/ex/jira/#{cloud}" }
      end

      # Same numeric paging as `jira`, plus a strict collection fence:
      # the shared host check allows any api.atlassian.com origin, so
      # additionally require the same /ex/jira/<cloud>/ prefix, the exact
      # requesting issue/collection path, paging-only query keys, and no
      # encoded or noncanonical path escapes. Rejected before any HTTP.
      def paged_get(ctx, headers, first_url, allowed_hosts, collection)
        items = []
        url = first_url
        seen = {}
        expected_start = 0
        expected_prefix = oauth_path_prefix(allowed_hosts)
        expected_path = oauth_collection_path(first_url, allowed_hosts)
        MAX_PAGES.times do
          incomplete!("Jira pagination did not advance") if seen[url]

          seen[url] = true
          response = ctx.transport.request(method: "GET", url: url, headers: headers, body: nil)
          payload = response.json
          page_items = payload.is_a?(Hash) ? payload[collection] : nil
          unless page_items.is_a?(Array)
            invalid_output!("Jira paged response had an unexpected shape")
          end

          nxt = payload["nextPage"]
          unless nxt.nil? || nxt == ""
            Http.check_host!(nxt, allowed_hosts)
            check_oauth_path!(nxt, expected_prefix, allowed_hosts,
                              expected_path: expected_path,
                              allowed_query_keys: ALLOWED_NEXT_QUERY_KEYS,
                              first_url: first_url)
          end
          start, maximum, total = payload.values_at("startAt", "maxResults", "total")
          unless [start, maximum, total].all? { |value| value.is_a?(Integer) && value >= 0 }
            invalid_output!("Jira pagination requires startAt, maxResults, and total")
          end
          incomplete!("Jira pagination did not advance") unless start == expected_start
          items.concat(page_items)
          next_start = start + page_items.length
          return items if next_start >= total && (nxt.nil? || nxt == "")

          if page_items.empty? || maximum.zero? || payload["isLast"] == true
            incomplete!("Jira pagination ended before all items were returned")
          end
          expected_start = next_start
          url = if nxt.nil? || nxt == ""
                  uri = URI.parse(first_url)
                  query = URI.decode_www_form(uri.query.to_s).to_h
                  uri.query = URI.encode_www_form(query.merge("startAt" => next_start.to_s))
                  uri.to_s
                else
                  nxt.to_s
                end
        end
        incomplete!("Jira comments or changelog exceeded the page limit")
      end

      def oauth_path_prefix(allowed_hosts)
        first = Array(allowed_hosts).first.to_s
        uri = URI.parse(first)
        segments = uri.path.to_s.split("/").reject(&:empty?)
        return segments if segments.length >= 3 && segments[0] == "ex" && segments[1] == "jira"

        raise HostRejected.new(host: uri.host.to_s.downcase,
                               allowed_hosts: Array(allowed_hosts).map(&:to_s))
      rescue URI::InvalidURIError
        raise HostRejected.new(host: "(invalid url)",
                               allowed_hosts: Array(allowed_hosts).map(&:to_s))
      end

      def oauth_collection_path(first_url, allowed_hosts)
        uri = URI.parse(first_url.to_s)
        path = uri.path.to_s
        reject_oauth_url!(uri, allowed_hosts) if path.empty?

        path
      rescue URI::InvalidURIError
        raise HostRejected.new(host: "(invalid url)",
                               allowed_hosts: Array(allowed_hosts).map(&:to_s))
      end

      def reject_oauth_url!(uri, allowed_hosts)
        raise HostRejected.new(host: uri.host.to_s.downcase,
                               allowed_hosts: Array(allowed_hosts).map(&:to_s))
      end

      # Rejects encoded and noncanonical path escapes before HTTP and pins
      # the page to the requesting issue/collection: the candidate path
      # must equal expected_path exactly and its query may only carry
      # paging keys. Any "%" in the raw path is rejected because the
      # canonical collection path is pure ASCII without encoding; this
      # covers %2e/%2f/%5c and double-encoded %25 without decoding
      # attacker-controlled text.
      def check_oauth_path!(url, expected_prefix, allowed_hosts,
                            expected_path: nil, allowed_query_keys: nil,
                            first_url: nil)
        uri = URI.parse(url.to_s)
        raw_path = uri.path.to_s
        if uri.fragment && !uri.fragment.empty?
          reject_oauth_url!(uri, allowed_hosts)
        end
        if raw_path.include?("\\") || raw_path.include?("%") || raw_path.include?("//") ||
           raw_path.include?("/../") || raw_path.include?("/./") ||
           raw_path.end_with?("/..") || raw_path.end_with?("/.") || raw_path.end_with?("/")
          reject_oauth_url!(uri, allowed_hosts)
        end
        segments = raw_path.split("/").reject(&:empty?)
        if segments.any? { |part| part == "." || part == ".." || part.empty? }
          reject_oauth_url!(uri, allowed_hosts)
        end
        unless segments[0, expected_prefix.length] == expected_prefix
          reject_oauth_url!(uri, allowed_hosts)
        end
        if expected_path && raw_path != expected_path
          reject_oauth_url!(uri, allowed_hosts)
        end
        if first_url
          begin
            first_uri = URI.parse(first_url.to_s)
          rescue URI::InvalidURIError
            reject_oauth_url!(uri, allowed_hosts)
          end
          unless uri.scheme.to_s.downcase == first_uri.scheme.to_s.downcase &&
                 uri.host.to_s.downcase == first_uri.host.to_s.downcase &&
                 uri.port == first_uri.port
            reject_oauth_url!(uri, allowed_hosts)
          end
        end
        if allowed_query_keys
          begin
            pairs = URI.decode_www_form(uri.query.to_s)
          rescue ArgumentError
            reject_oauth_url!(uri, allowed_hosts)
          end
          unless pairs.all? { |key, _| allowed_query_keys.include?(key) }
            reject_oauth_url!(uri, allowed_hosts)
          end
        end
        uri
      rescue URI::InvalidURIError
        raise HostRejected.new(host: "(invalid url)",
                               allowed_hosts: Array(allowed_hosts).map(&:to_s))
      end
    end
  end
end
