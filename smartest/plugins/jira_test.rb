# frozen_string_literal: true

require_relative "plugins_test_helper"
require "tempfile"

Plugins = Aiconshell::Plugins
JIRA = "https://aiconshell-test.atlassian.net"

def jira_adf_paragraph(text)
  { "type" => "doc", "version" => 1,
    "content" => [{ "type" => "paragraph",
                    "content" => [{ "type" => "text", "text" => text }] }] }
end

def jira_issue(key, updated:, summary: "summary", description: nil, status: "To Do")
  { "id" => "100#{key.split('-').last}", "key" => key,
    "fields" => { "summary" => summary,
                  "description" => description || jira_adf_paragraph("desc of #{key}"),
                  "status" => { "name" => status },
                  "updated" => updated, "created" => "2026-09-20T10:00:00.000+0000" } }
end

def jira_page(collection, values, start_at: 0, max_results: 50, total: nil)
  { collection => values, "startAt" => start_at, "maxResults" => max_results,
    "total" => total || values.length }
end

def jira_empty_children(transport)
  transport.stub_json("GET", %r{/issue/[^/]+/comment\?}, body: jira_page("comments", []))
  transport.stub_json("GET", %r{/issue/[^/]+/changelog\?}, body: jira_page("values", []))
end

def jira_comment(id, updated:, text: "comment", author: "u1")
  { "id" => id, "body" => jira_adf_paragraph(text),
    "created" => "2026-09-20T12:00:00Z", "updated" => updated,
    "author" => { "accountId" => author, "accountType" => "atlassian" } }
end

test("jira poll posts Enhanced JQL and pages comments plus changelog") do |registry:, transport:, plugin_env:|
  seen_bodies = []
  transport.stub_proc("POST", "#{JIRA}/rest/api/3/search/jql") do |req|
    body = JSON.parse(req[:body])
    seen_bodies << body
    older = body["jql"].include?("updated < ")
    issues = older || body["nextPageToken"] ? [] : [jira_issue("PROJ-1", updated: "2026-09-26T12:01:00.000+0000")]
    payload = { "issues" => issues }
    payload["nextPageToken"] = "tok-2" unless older || body["nextPageToken"]
    Plugins::Http::Response.new(status: 200, headers: {}, body: JSON.generate(payload))
  end
  transport.stub_json("GET", %r{/rest/api/3/issue/PROJ-1/comment}, body: {
                        "startAt" => 0, "maxResults" => 50, "total" => 2,
                        "comments" => [
                          { "id" => "200", "body" => jira_adf_paragraph("first"),
                            "created" => "2026-09-26T12:02:00.000+0000",
                            "updated" => "2026-09-26T12:02:00.000+0000",
                            "author" => { "accountId" => "u1", "accountType" => "atlassian" } },
                          { "id" => "201", "body" => jira_adf_paragraph("second"),
                            "created" => "2026-09-26T12:03:00.000+0000",
                            "updated" => "2026-09-26T12:03:00.000+0000",
                            "author" => { "accountId" => "app1", "accountType" => "app" } }
                        ]
                      })
  transport.stub_json("GET", %r{/rest/api/3/issue/PROJ-1/changelog}, body: {
                        "startAt" => 0, "maxResults" => 100, "total" => 1,
                        "values" => [
                          { "id" => "300", "created" => "2026-09-26T12:04:00.000+0000",
                            "author" => { "accountId" => "u1", "accountType" => "atlassian" },
                            "items" => [{ "field" => "status", "fromString" => "To Do",
                                          "toString" => "In Progress" }] }
                        ]
                      })

  out = registry.invoke(plugin: "jira", operation: "latest_events",
                        input: { "scope" => "PROJ",
                                 "cursor" => { "since" => "2026-09-26T11:00:00.000+0000" } },
                        context: {})

  expect(seen_bodies[0]["jql"]).to eq('project = PROJ AND updated >= "2026-09-26 10:55" ORDER BY updated ASC')
  expect(seen_bodies.size).to eq(3)
  expect(seen_bodies[1]["nextPageToken"]).to eq("tok-2")
  expect(seen_bodies[2]["jql"]).to eq('project = PROJ AND updated < "2026-09-26 10:55" ORDER BY updated ASC')

  ids = out["events"].map { |e| e["event_id"] }
  expect(ids.first(3)).to eq(["jira:issue:PROJ-1", "jira:comment:200", "jira:comment:201"])
  expect(ids[3]).to match(/\Ajira:changelog:\d+:300\z/)
  expect(out["events"][0]["event_type"]).to eq("jira.issue")
  expect(out["events"][1]["payload"]["text"]).to eq("first")
  expect(out["events"][2]["actor_type"]).to eq("bot")
  expect(out["events"][3]["event_type"]).to eq("jira.change")
  expect(out["events"][3]["payload"]["items"]).to eq(["status:To Do->In Progress"])
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T12:04:00Z" })

  basic = Base64.strict_decode64(
    transport.requests.first[:headers]["Authorization"].sub("Basic ", "")
  )
  expect(basic).to eq("bot@example.com:jira-api-token")
end

test("jira extracts plain text from ADF documents") do |registry:, transport:|
  description = {
    "type" => "doc", "version" => 1,
    "content" => [
      { "type" => "heading", "attrs" => { "level" => 1 },
        "content" => [{ "type" => "text", "text" => "Title" }] },
      { "type" => "paragraph",
        "content" => [{ "type" => "text", "text" => "hello " },
                      { "type" => "mention", "attrs" => { "text" => "@ana" } },
                      { "type" => "hardBreak" },
                      { "type" => "emoji", "attrs" => { "shortName" => ":wave:" } }] },
      { "type" => "bulletList",
        "content" => [{ "type" => "listItem",
                        "content" => [{ "type" => "paragraph",
                                        "content" => [{ "type" => "text", "text" => "item" }] }] }] }
    ]
  }
  transport.stub_json("POST", "#{JIRA}/rest/api/3/search/jql",
                      body: { "issues" => [jira_issue("PROJ-9", updated: "2026-09-26T12:01:00Z",
                                                     description: description)] })
  jira_empty_children(transport)

  out = registry.invoke(plugin: "jira", operation: "latest_events",
                        input: { "scope" => "PROJ" }, context: {})

  text = out["events"][0]["payload"]["text"]
  expect(text).to include("Title")
  expect(text).to include("hello @ana")
  expect(text).to include("item")
  jql = JSON.parse(transport.requests.first[:body])["jql"]
  expect(jql).to eq("project = PROJ ORDER BY updated ASC")
end

test("jira refuses cross-host nextPage URLs without sending credentials") do |registry:, transport:|
  transport.stub_json("POST", "#{JIRA}/rest/api/3/search/jql",
                      body: { "issues" => [jira_issue("PROJ-1", updated: "2026-09-26T12:01:00Z")] })
  transport.stub_json("GET", %r{/issue/PROJ-1/comment}, body: {
                        "comments" => [],
                        "nextPage" => "https://evil.test/api/comments?token=2"
                      })
  transport.stub_json("GET", %r{/issue/PROJ-1/changelog}, body: jira_page("values", []))

  expect do
    registry.invoke(plugin: "jira", operation: "latest_events",
                    input: { "scope" => "PROJ" }, context: {})
  end.to raise_error(Plugins::HostRejected, /evil\.test/)
  expect(transport.requests_to(%r{evil\.test}).size).to eq(0)
end

test("jira supports the scoped-token host via cloud id") do |registry:, transport:, plugin_env:|
  plugin_env.delete("JIRA_SITE_URL")
  plugin_env["JIRA_CLOUD_ID"] = "cloud-123"
  scoped = "https://api.atlassian.com/ex/jira/cloud-123"
  transport.stub_json("POST", "#{scoped}/rest/api/3/search/jql", body: { "issues" => [] })

  out = registry.invoke(plugin: "jira", operation: "latest_events",
                        input: { "scope" => "PROJ" }, context: {})
  expect(out["events"]).to eq([])
  expect(transport.requests.first[:url]).to start_with(scoped)

  transport.stub_json("POST", "#{scoped}/rest/api/3/issue/PROJ-2/comment",
                      status: 201, body: { "id" => "900" })
  out = registry.invoke(plugin: "jira", operation: "reply",
                        input: { "resource_id" => "issue:PROJ-2", "body" => "ack" },
                        context: {})
  # Scoped host has no /browse path, so url is null per contract.
  expect(out).to eq({ "external_id" => "900", "url" => nil })
end

test("jira reply and create_issue send ADF payloads") do |registry:, transport:|
  transport.stub_json("POST", "#{JIRA}/rest/api/3/issue/PROJ-1/comment",
                      status: 201, body: { "id" => "500" })
  out = registry.invoke(plugin: "jira", operation: "reply",
                        input: { "resource_id" => "issue:PROJ-1", "body" => "on it" },
                        context: {})
  expect(out).to eq({ "external_id" => "500",
                      "url" => "#{JIRA}/browse/PROJ-1" })
  comment_body = JSON.parse(transport.requests.last[:body])
  expect(comment_body["body"]["type"]).to eq("doc")
  expect(comment_body["body"]["content"][0]["content"][0]["text"]).to eq("on it")

  transport.stub_json("POST", "#{JIRA}/rest/api/3/issue", status: 201,
                      body: { "id" => "101", "key" => "PROJ-42" })
  out = registry.invoke(plugin: "jira", operation: "create_issue",
                        input: { "scope" => "PROJ", "title" => "bug", "body" => "steps" },
                        context: {})
  expect(out).to eq({ "external_id" => "PROJ-42", "url" => "#{JIRA}/browse/PROJ-42" })
  issue_body = JSON.parse(transport.requests.last[:body])
  expect(issue_body["fields"]["project"]).to eq({ "key" => "PROJ" })
  expect(issue_body["fields"]["summary"]).to eq("bug")
  expect(issue_body["fields"]["issuetype"]).to eq({ "name" => "Task" })
end

test("jira requires email, token, and one endpoint before I/O") do |registry:, transport:, plugin_env:|
  plugin_env.delete("JIRA_API_TOKEN")
  expect do
    registry.invoke(plugin: "jira", operation: "latest_events",
                    input: { "scope" => "PROJ" }, context: {})
  end.to raise_error(Plugins::CredentialsMissing, /JIRA_API_TOKEN/)
  expect(transport.requests).to eq([])

  plugin_env["JIRA_API_TOKEN"] = "x"
  plugin_env.delete("JIRA_SITE_URL")
  expect do
    registry.invoke(plugin: "jira", operation: "latest_events",
                    input: { "scope" => "PROJ" }, context: {})
  end.to raise_error(Plugins::CredentialsMissing, /JIRA_SITE_URL/)
  expect(transport.requests).to eq([])
end

test("jira accepts API token files in diagnostics and read and write guards") do |registry:, transport:, plugin_env:|
  Tempfile.create("jira-token") do |file|
    file.write("file-token\n")
    file.flush
    plugin_env.delete("JIRA_API_TOKEN")
    plugin_env["JIRA_API_TOKEN_FILE"] = file.path
    expect(registry.catalog.find { |plugin| plugin["id"] == "jira" }["configured"]).to eq(true)
    transport.stub_json("POST", "#{JIRA}/rest/api/3/search/jql", body: { "issues" => [] })
    transport.stub_json("POST", "#{JIRA}/rest/api/3/issue/PROJ-1/comment", body: { "id" => "1" })
    registry.invoke(plugin: "jira", operation: "latest_events", input: { "scope" => "PROJ" })
    registry.invoke(plugin: "jira", operation: "reply",
                    input: { "resource_id" => "issue:PROJ-1", "body" => "ack" })
    credentials = transport.requests.map { |request| Base64.strict_decode64(request[:headers]["Authorization"].sub("Basic ", "")) }
    expect(credentials.uniq).to eq(["bot@example.com:file-token"])
  end
end

test("jira rejects injected, invalid, and timezone-free cursors before I/O") do |registry:, transport:|
  invalid = ['2026-09-26" OR project = SECRET', "2026-02-30T12:00:00Z",
             "2026-09-26T24:00:00Z", "2026-09-26T12:00:00", "2026-09-26", 42]
  invalid.each do |since|
    expect do
      registry.invoke(plugin: "jira", operation: "latest_events",
                      input: { "scope" => "PROJ", "cursor" => { "since" => since } })
    end.to raise_error(Plugins::InputInvalid, /ISO8601/)
  end
  expect(transport.requests).to eq([])
end

test("jira converts offset cursors to UTC minute JQL with overlap") do |registry:, transport:|
  transport.stub_json("POST", "#{JIRA}/rest/api/3/search/jql", body: { "issues" => [] })
  out = registry.invoke(plugin: "jira", operation: "latest_events",
                        input: { "scope" => "*", "cursor" => { "since" => "2026-09-26T21:04:49.125+09:00" } })
  queries = transport.requests.map { |request| JSON.parse(request[:body])["jql"] }
  expect(queries).to eq(['updated >= "2026-09-26 11:59" ORDER BY updated ASC',
                        'updated < "2026-09-26 11:59" ORDER BY updated ASC'])
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T12:04:49.125000Z" })
end

test("jira requires a search restriction for an initial wildcard poll") do |registry:, transport:|
  expect do
    registry.invoke(plugin: "jira", operation: "latest_events", input: { "scope" => "*" })
  end.to raise_error(Plugins::InputInvalid, /requires cursor.since/)
  expect(transport.requests).to eq([])
end

test("jira follows numeric comment and changelog pages using returned offsets") do |registry:, transport:|
  transport.stub_json("POST", "#{JIRA}/rest/api/3/search/jql",
                      body: { "issues" => [jira_issue("PROJ-1", updated: "2026-09-26T12:00:00Z")] })
  offsets = { "comments" => [], "values" => [] }
  { "comment" => "comments", "changelog" => "values" }.each do |endpoint, collection|
    transport.stub_proc("GET", %r{/issue/PROJ-1/#{endpoint}\?}) do |request|
      start = URI.decode_www_form(URI(request[:url]).query).to_h.fetch("startAt").to_i
      offsets[collection] << start
      entry = if collection == "comments"
                jira_comment("c#{start}", updated: "2026-09-26T12:01:00Z")
              else
                { "id" => "h#{start}", "created" => "2026-09-26T12:02:00Z", "items" => [] }
              end
      Plugins::Http::Response.new(status: 200, headers: {},
                                  body: JSON.generate(jira_page(collection, [entry], start_at: start, max_results: 1, total: 2)))
    end
  end
  out = registry.invoke(plugin: "jira", operation: "latest_events", input: { "scope" => "PROJ" })
  expect(offsets).to eq({ "comments" => [0, 1], "values" => [0, 1] })
  expect(out["events"].count { |event| event["event_type"] == "jira.comment" }).to eq(2)
  expect(out["events"].count { |event| event["event_type"] == "jira.change" }).to eq(2)
end

test("jira reconciles edits on old issues and compares timestamp instants with overlap") do |registry:, transport:|
  transport.stub_proc("POST", "#{JIRA}/rest/api/3/search/jql") do |request|
    older = JSON.parse(request[:body])["jql"].include?("updated < ")
    issues = older ? [jira_issue("PROJ-1", updated: "2026-09-01T12:00:00Z")] : []
    Plugins::Http::Response.new(status: 200, headers: {}, body: JSON.generate({ "issues" => issues }))
  end
  comments = [jira_comment("edited", updated: "2026-09-26T05:01:00-07:00", text: "edited body"),
              jira_comment("equal", updated: "2026-09-26T12:00:00Z"),
              jira_comment("delayed", updated: "2026-09-26T11:55:00Z"),
              jira_comment("old", updated: "2026-09-26T20:00:00+09:00")]
  comments.first["updateAuthor"] = { "accountId" => "editor" }
  transport.stub_json("GET", %r{/issue/PROJ-1/comment}, body: jira_page("comments", comments))
  transport.stub_json("GET", %r{/issue/PROJ-1/changelog}, body: jira_page("values", []))
  out = registry.invoke(plugin: "jira", operation: "latest_events",
                        input: { "scope" => "PROJ", "cursor" => { "since" => "2026-09-26T12:00:00Z" } })
  expect(out["events"].map { |event| event["event_id"] }).to eq(["jira:comment:delayed", "jira:comment:equal", "jira:comment:edited"])
  expect(out["events"].last["actor_id"]).to eq("editor")
  expect(out["events"].last["payload"]["text"]).to eq("edited body")
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T12:01:00Z" })
end

test("jira preserves edit fingerprints at equal timestamps") do |registry:, transport:|
  transport.stub_json("POST", "#{JIRA}/rest/api/3/search/jql",
                      body: { "issues" => [jira_issue("PROJ-1", updated: "2026-09-26T12:00:00Z")] })
  version = 0
  transport.stub_proc("GET", %r{/issue/PROJ-1/comment}) do |_request|
    version += 1
    comment = jira_comment("1", updated: "2026-09-26T12:01:00Z", text: "body #{version}")
    Plugins::Http::Response.new(status: 200, headers: {}, body: JSON.generate(jira_page("comments", [comment])))
  end
  transport.stub_json("GET", %r{/issue/PROJ-1/changelog}, body: jira_page("values", []))
  first = registry.invoke(plugin: "jira", operation: "latest_events", input: { "scope" => "PROJ" })
  second = registry.invoke(plugin: "jira", operation: "latest_events",
                           input: { "scope" => "PROJ", "cursor" => first["cursor"] })
  before = first["events"].find { |event| event["event_type"] == "jira.comment" }
  after = second["events"].find { |event| event["event_type"] == "jira.comment" }
  expect(after["event_id"]).to eq(before["event_id"])
  expect(after["fingerprint"]).not_to eq(before["fingerprint"])
end

test("jira emits all issues when a response contains more than fifty") do |registry:, transport:|
  issues = (1..51).map { |number| jira_issue("PROJ-#{number}", updated: "2026-09-26T12:00:00Z") }
  transport.stub_json("POST", "#{JIRA}/rest/api/3/search/jql", body: { "issues" => issues, "isLast" => true })
  jira_empty_children(transport)
  out = registry.invoke(plugin: "jira", operation: "latest_events", input: { "scope" => "PROJ" })
  expect(out["events"].size).to eq(51)
  expect(out["events"].map { |event| event["resource_id"] }).to include("issue:PROJ-51")
  expect(transport.requests_to(%r{/comment\?}).size).to eq(51)
end

test("jira raises incomplete poll at the search page cap and leaves input cursor unchanged") do |registry:, transport:|
  page = 0
  transport.stub_proc("POST", "#{JIRA}/rest/api/3/search/jql") do |_request|
    page += 1
    Plugins::Http::Response.new(status: 200, headers: {},
                                body: JSON.generate({ "issues" => [], "nextPageToken" => "page-#{page}" }))
  end
  cursor = { "since" => "2026-09-26T12:00:00Z" }
  expect do
    registry.invoke(plugin: "jira", operation: "latest_events", input: { "scope" => "PROJ", "cursor" => cursor })
  end.to raise_error(Plugins::IncompletePoll, /page limit/)
  expect(page).to eq(Plugins::Jira::MAX_PAGES)
  expect(cursor).to eq({ "since" => "2026-09-26T12:00:00Z" })
end

%w[comment changelog].each do |endpoint|
  test("jira raises incomplete poll at the #{endpoint} page cap") do |registry:, transport:|
    transport.stub_json("POST", "#{JIRA}/rest/api/3/search/jql",
                        body: { "issues" => [jira_issue("PROJ-1", updated: "2026-09-26T12:00:00Z")] })
    if endpoint == "changelog"
      transport.stub_json("GET", %r{/issue/PROJ-1/comment}, body: jira_page("comments", []))
    end
    page = 0
    transport.stub_proc("GET", %r{/issue/PROJ-1/#{endpoint}\?}) do |_request|
      start = page
      page += 1
      collection = endpoint == "comment" ? "comments" : "values"
      Plugins::Http::Response.new(status: 200, headers: {},
                                  body: JSON.generate(jira_page(collection, [{ "id" => page.to_s }], start_at: start,
                                                                max_results: 1, total: Plugins::Jira::MAX_PAGES + 1)))
    end
    expect do
      registry.invoke(plugin: "jira", operation: "latest_events", input: { "scope" => "PROJ" })
    end.to raise_error(Plugins::IncompletePoll, /page limit/)
    expect(page).to eq(Plugins::Jira::MAX_PAGES)
  end
end

test("jira fails when pagination metadata is absent instead of advancing the cursor") do |registry:, transport:|
  transport.stub_json("POST", "#{JIRA}/rest/api/3/search/jql",
                      body: { "issues" => [jira_issue("PROJ-1", updated: "2026-09-26T12:00:00Z")] })
  transport.stub_json("GET", %r{/issue/PROJ-1/comment}, body: { "comments" => [] })
  expect do
    registry.invoke(plugin: "jira", operation: "latest_events", input: { "scope" => "PROJ" })
  end.to raise_error(Plugins::OutputInvalid, /startAt/)
end

test("jira fails on a stalled numeric page and does not return partial events") do |registry:, transport:|
  transport.stub_json("POST", "#{JIRA}/rest/api/3/search/jql",
                      body: { "issues" => [jira_issue("PROJ-1", updated: "2026-09-26T12:00:00Z")] })
  transport.stub_json("GET", %r{/issue/PROJ-1/comment}, body: jira_page("comments", [], total: 1))
  expect do
    registry.invoke(plugin: "jira", operation: "latest_events", input: { "scope" => "PROJ" })
  end.to raise_error(Plugins::IncompletePoll, /before all items/)
end

test("jira rejects unsafe same-host pagination origins") do |registry:, transport:|
  transport.stub_json("POST", "#{JIRA}/rest/api/3/search/jql",
                      body: { "issues" => [jira_issue("PROJ-1", updated: "2026-09-26T12:00:00Z")] })
  links = [JIRA.sub("https:", "http:") + "/next", "#{JIRA}:8443/next",
           "https://user:secret@aiconshell-test.atlassian.net/next"]
  transport.stub_proc("GET", %r{/issue/PROJ-1/comment}) do |_request|
    Plugins::Http::Response.new(status: 200, headers: {},
                                body: JSON.generate(jira_page("comments", []).merge("nextPage" => links.shift)))
  end
  3.times do
    expect do
      registry.invoke(plugin: "jira", operation: "latest_events", input: { "scope" => "PROJ" })
    end.to raise_error(Plugins::HostRejected)
  end
  expect(transport.requests_to(%r{/next}).size).to eq(0)
end
