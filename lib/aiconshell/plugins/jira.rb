# frozen_string_literal: true

require "base64"
require "date"
require "json"
require "time"
require "uri"

module Aiconshell
  module Plugins
    # Jira Cloud adapter (service account e-mail + API token, Basic auth).
    #
    # Polling uses Enhanced JQL via POST /rest/api/3/search/jql plus per-issue
    # comment and changelog paging. Bodies are Atlassian Document Format (ADF);
    # plain text is extracted for fingerprints and payloads.
    #
    # Endpoint resolution: JIRA_BASE_URL, else JIRA_SITE_URL
    # (https://<site>.atlassian.net), else the scoped-token host
    # https://api.atlassian.com/ex/jira/<cloudId> from JIRA_CLOUD_ID.
    #
    # Scope: Jira project key (e.g. "PROJ") or "*" for all visible projects.
    # latest_events cursor: {"since": ISO8601}.
    class Jira < Base
      plugin_id "jira"
      required_env "JIRA_EMAIL", "JIRA_API_TOKEN", "JIRA_API_TOKEN_FILE",
                   "JIRA_SITE_URL", "JIRA_CLOUD_ID", "JIRA_BASE_URL",
                   "JIRA_SERVICE_ACCOUNT_ID"

      operation "latest_events",
                input_schema: Schemas::LATEST_EVENTS_INPUT,
                output_schema: Schemas::LATEST_EVENTS_OUTPUT,
                scope: "jira:read",
                read_only: true
      operation "reply",
                input_schema: Schemas::REPLY_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "jira:write"
      operation "create_issue",
                input_schema: Schemas::CREATE_ISSUE_INPUT,
                output_schema: Schemas::WRITE_OUTPUT,
                scope: "jira:write"

      PROJECT_PATTERN = /\A[A-Z][A-Z0-9_]+\z/
      RESOURCE_PATTERN = %r{\Aissue:(?<key>[A-Za-z][A-Za-z0-9_]*-\d+)\z}
      SCOPED_HOST = "api.atlassian.com"
      MAX_PAGES = 25
      PER_PAGE = 50
      OVERLAP_SECONDS = 300
      TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):?[0-5]\d)\z/

      # email + token + exactly one endpoint source (base URL wins, then site,
      # then cloud id).
      def configured?(env)
        present?(env["JIRA_EMAIL"]) &&
          (present?(env["JIRA_API_TOKEN"]) || present?(env["JIRA_API_TOKEN_FILE"])) &&
          (present?(env["JIRA_BASE_URL"]) || present?(env["JIRA_SITE_URL"]) ||
           present?(env["JIRA_CLOUD_ID"]))
      end

      private

      def handle_latest_events(input, ctx)
        scope = input["scope"].to_s
        project = scope == "*" ? nil : scope
        if project && !PROJECT_PATTERN.match?(project)
          raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                 details: ['scope must be a Jira project key like "PROJ" or "*"'])
        end

        cursor = validated_cursor(input, "latest_events")
        since = cursor_since(cursor)
        if project.nil? && since.nil?
          raise InputInvalid.new(plugin: plugin_id, operation: "latest_events",
                                 details: ['scope "*" requires cursor.since; use a project scope for an initial import'])
        end
        cutoff = since && since - OVERLAP_SECONDS
        base = base_url(ctx.env)
        headers = auth_headers(ctx.env)

        events = []
        watermark = since
        # Comment edits need not move the parent issue's updated timestamp.
        # Scan both partitions, including old issues, before returning a cursor.
        boundary = cutoff && cutoff.utc.strftime("%Y-%m-%d %H:%M")
        clauses = boundary ? [%(updated >= "#{boundary}"), %(updated < "#{boundary}")] : [nil]
        seen_issues = {}
        clauses.each do |clause|
          predicates = [project && "project = #{project}", clause].compact
          jql = [predicates.join(" AND "), "ORDER BY updated ASC"].reject(&:empty?).join(" ")
          search_issues(ctx, headers, base, jql).each do |issue|
            unless issue.is_a?(Hash) && RESOURCE_PATTERN.match?("issue:#{issue['key']}") &&
                   issue["fields"].is_a?(Hash)
              invalid_output!("Jira issue response had an unexpected shape")
            end
            # A concurrently updated issue can appear in both partitions.
            version = [issue["key"], issue.dig("fields", "updated")]
            next if seen_issues[version]

            seen_issues[version] = true
            watermark = emit_issue_events(ctx, headers, base, issue, cutoff, watermark, events)
          end
        end

        events.uniq! { |event| [event["event_id"], event["fingerprint"]] }
        events.sort_by! { |event| parse_timestamp(event["occurred_at"]) }
        watermark ||= ctx.clock.now
        { "events" => events, "cursor" => { "since" => timestamp_string(watermark) } }
      end

      def search_issues(ctx, headers, base, jql)
        issues = []
        page_token = nil
        seen_tokens = {}
        page_count = 0
        loop do
          body = { "jql" => jql, "maxResults" => PER_PAGE,
                   "fields" => %w[summary description status updated created project],
                   "fieldsByKeys" => false }
          body["nextPageToken"] = page_token if page_token
          response = ctx.transport.request(
            method: "POST", url: "#{base}/rest/api/3/search/jql",
            headers: post_headers(headers), body: JSON.generate(body)
          )
          payload = response.json
          page_issues = payload.is_a?(Hash) ? payload["issues"] : nil
          unless page_issues.is_a?(Array)
            invalid_output!("Jira /search/jql response had an unexpected shape")
          end
          issues.concat(page_issues)

          page_token = payload["nextPageToken"]
          if page_token.nil? || page_token == ""
            incomplete!("Jira search omitted the next page token") if payload["isLast"] == false
            break
          end
          invalid_output!("Jira next page token must be a string") unless page_token.is_a?(String)
          page_count += 1
          incomplete!("Jira search exceeded the page limit") if page_count >= MAX_PAGES
          incomplete!("Jira search pagination did not advance") if seen_tokens[page_token]
          seen_tokens[page_token] = true
        end
        issues
      end

      def emit_issue_events(ctx, headers, base, issue, cutoff, watermark, events)
        key = issue["key"].to_s
        fields = issue["fields"] || {}
        updated = parse_timestamp(fields["updated"])
        summary = fields["summary"].to_s
        description_text = adf_text(fields["description"])
        status = fields.dig("status", "name").to_s

        events << {
          "event_id" => "jira:issue:#{key}",
          # Child comments can move updated without changing the issue itself.
          "fingerprint" => fingerprint(summary, description_text, status),
          "event_type" => "jira.issue",
          "resource_id" => "issue:#{key}",
          "actor_id" => "unknown",
          "actor_type" => "system",
          "occurred_at" => timestamp_string(updated),
          "payload" => {
            "key" => key, "summary" => summary, "text" => description_text,
            "status" => status, "url" => browse_url(base, key)
          }
        } unless cutoff && updated < cutoff
        watermark = max_time(watermark, updated)

        comments_url = "#{base}/rest/api/3/issue/#{uri_escape(key)}/comment" \
                       "?startAt=0&maxResults=#{PER_PAGE}&orderBy=created"
        paged_get(ctx, headers, comments_url, [base], "comments").each do |comment|
          invalid_output!("Jira comment had an unexpected shape") unless comment.is_a?(Hash) && present?(comment["id"])
          cu = parse_timestamp(comment["updated"] || comment["created"])
          next if cutoff && cu < cutoff

          text = adf_text(comment["body"])
          events << {
            "event_id" => "jira:comment:#{comment["id"]}",
            "fingerprint" => fingerprint(timestamp_string(cu), text),
            "event_type" => "jira.comment",
            "resource_id" => "issue:#{key}",
            "actor_id" => jira_actor_id(comment["updateAuthor"] || comment["author"]),
            "actor_type" => jira_actor_type(comment["updateAuthor"] || comment["author"]),
            "occurred_at" => timestamp_string(cu),
            "payload" => { "key" => key, "comment_id" => comment["id"].to_s, "text" => text }
          }
          watermark = max_time(watermark, cu)
        end

        changelog_url = "#{base}/rest/api/3/issue/#{uri_escape(key)}/changelog?startAt=0&maxResults=100"
        paged_get(ctx, headers, changelog_url, [base], "values").each do |change|
          invalid_output!("Jira changelog had an unexpected shape") unless change.is_a?(Hash) && present?(change["id"])
          created = parse_timestamp(change["created"])
          next if cutoff && created < cutoff

          items = Array(change["items"]).map do |item|
            "#{item["field"]}:#{item["fromString"]}->#{item["toString"]}"
          end
          events << {
            "event_id" => "jira:changelog:#{issue["id"]}:#{change["id"]}",
            "fingerprint" => fingerprint(timestamp_string(created), items.join(",")),
            "event_type" => "jira.change",
            "resource_id" => "issue:#{key}",
            "actor_id" => jira_actor_id(change["author"]),
            "actor_type" => jira_actor_type(change["author"]),
            "occurred_at" => timestamp_string(created),
            "payload" => { "key" => key, "change_id" => change["id"].to_s, "items" => items }
          }
          watermark = max_time(watermark, created)
        end

        watermark
      end

      def handle_reply(input, ctx)
        match = RESOURCE_PATTERN.match(input["resource_id"].to_s)
        unless match
          raise InputInvalid.new(plugin: plugin_id, operation: "reply",
                                 details: ['resource_id must look like "issue:PROJ-123"'])
        end

        base = base_url(ctx.env)
        response = ctx.transport.request(
          method: "POST",
          url: "#{base}/rest/api/3/issue/#{uri_escape(match[:key])}/comment",
          headers: post_headers(auth_headers(ctx.env)),
          body: JSON.generate({ "body" => adf_doc(input["body"].to_s) })
        )
        payload = response.json
        unless payload.is_a?(Hash) && payload["id"]
          raise OutputInvalid.new(plugin: plugin_id, operation: "reply",
                                  details: ["Jira response did not include a comment id"])
        end

        { "external_id" => payload["id"].to_s, "url" => browse_url(base, match[:key]) }
      end

      def handle_create_issue(input, ctx)
        scope = input["scope"].to_s
        unless PROJECT_PATTERN.match?(scope)
          raise InputInvalid.new(plugin: plugin_id, operation: "create_issue",
                                 details: ['scope must be a Jira project key like "PROJ"'])
        end

        base = base_url(ctx.env)
        response = ctx.transport.request(
          method: "POST", url: "#{base}/rest/api/3/issue",
          headers: post_headers(auth_headers(ctx.env)),
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
        unless payload.is_a?(Hash) && payload["key"]
          raise OutputInvalid.new(plugin: plugin_id, operation: "create_issue",
                                  details: ["Jira response did not include an issue key"])
        end

        { "external_id" => payload["key"].to_s, "url" => browse_url(base, payload["key"].to_s) }
      end

      # -- endpoint + auth ------------------------------------------------

      def base_url(env)
        missing = []
        missing << "JIRA_EMAIL" unless present?(env["JIRA_EMAIL"])
        unless present?(env["JIRA_API_TOKEN"]) || present?(env["JIRA_API_TOKEN_FILE"])
          missing << "JIRA_API_TOKEN or JIRA_API_TOKEN_FILE"
        end
        require_credentials!(missing)

        raw = if present?(env["JIRA_BASE_URL"])
                env["JIRA_BASE_URL"]
              elsif present?(env["JIRA_SITE_URL"])
                env["JIRA_SITE_URL"]
              elsif present?(env["JIRA_CLOUD_ID"])
                "https://#{SCOPED_HOST}/ex/jira/#{env["JIRA_CLOUD_ID"].to_s.strip}"
              end
        if raw.nil? || raw.to_s.strip.empty?
          require_credentials!(["JIRA_SITE_URL or JIRA_CLOUD_ID or JIRA_BASE_URL"])
        end

        begin
          uri = URI.parse(raw.to_s.strip.chomp("/"))
        rescue URI::InvalidURIError
          uri = nil
        end
        unless uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty? &&
               uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
          raise CredentialsMissing.new(plugin: plugin_id,
                                       missing: ["Jira endpoint must be an https URL"])
        end

        "#{uri.scheme}://#{uri.host}#{":#{uri.port}" if uri.port != uri.default_port}#{uri.path}"
      end

      def auth_headers(env)
        email = env["JIRA_EMAIL"].to_s
        token = secret_from(env, "JIRA_API_TOKEN", "JIRA_API_TOKEN_FILE")
        if token.nil? || token.empty?
          require_credentials!(["JIRA_API_TOKEN or JIRA_API_TOKEN_FILE"])
        end

        { "Authorization" => "Basic #{Base64.strict_encode64("#{email}:#{token}")}",
          "Accept" => "application/json" }
      end

      def post_headers(headers)
        headers.merge("Content-Type" => "application/json")
      end

      def browse_url(base, key)
        host = URI.parse(base).host.to_s.downcase
        return nil if host == SCOPED_HOST # scoped host has no /browse path

        "#{base}/browse/#{key}"
      rescue URI::InvalidURIError
        nil
      end

      # -- paging ---------------------------------------------------------

      # Comments use offset metadata; changelog may also include nextPage.
      # A short page alone does not prove exhaustion. Never return partial data.
      def paged_get(ctx, headers, first_url, allowed_hosts, collection)
        items = []
        url = first_url
        seen = {}
        expected_start = 0
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
          Http.check_host!(nxt, allowed_hosts) unless nxt.nil? || nxt == ""
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

      # -- ADF ------------------------------------------------------------

      BLOCK_SEPARATORS = {
        "doc" => "\n", "paragraph" => "", "heading" => "",
        "bulletList" => "\n", "orderedList" => "\n", "listItem" => "",
        "blockquote" => "\n", "codeBlock" => "\n", "panel" => "\n",
        "table" => "\n", "tableRow" => " | ", "tableCell" => "",
        "mediaGroup" => "\n", "mediaSingle" => "\n"
      }.freeze

      # Best-effort plain-text extraction from an ADF document (or nil).
      def adf_text(node)
        case node
        when nil then ""
        when String then node
        when Array then node.map { |child| adf_text(child) }.join("\n")
        when Hash
          case node["type"]
          when "text" then node["text"].to_s
          when "hardBreak" then "\n"
          when "mention"
            node.dig("attrs", "text").to_s.empty? ? "@mention" : node.dig("attrs", "text").to_s
          when "emoji"
            attrs = node["attrs"] || {}
            attrs["text"] || attrs["shortName"] || ""
          when "media"
            attrs = node["attrs"] || {}
            title = attrs["alt"] || attrs["fileName"] || "attachment"
            "[#{title}]"
          when "inlineCard", "blockCard"
            url = node.dig("attrs", "url").to_s
            url.empty? ? "[card]" : url
          else
            children = Array(node["content"]).map { |child| adf_text(child) }
            separator = BLOCK_SEPARATORS.fetch(node["type"], "")
            # Nested blocks still need newlines even when the parent joins inline.
            separator.empty? && children.any? { |c| c.include?("\n") } ? children.join : children.join(separator)
          end
        else
          ""
        end
      end

      def adf_doc(text)
        {
          "type" => "doc", "version" => 1,
          "content" => text.to_s.split("\n", -1).map do |line|
            { "type" => "paragraph",
              "content" => line.empty? ? [] : [{ "type" => "text", "text" => line }] }
          end
        }
      end

      # -- helpers --------------------------------------------------------

      def jira_actor_id(author)
        id = author.is_a?(Hash) ? (author["accountId"] || author["emailAddress"]) : nil
        id.nil? || id.to_s.empty? ? "unknown" : id.to_s
      end

      def jira_actor_type(author)
        author.is_a?(Hash) && author["accountType"].to_s == "app" ? "bot" : "human"
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
                        details: [input ? "cursor.since must be a valid ISO8601 timestamp" : "Jira returned an invalid timestamp"])
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
