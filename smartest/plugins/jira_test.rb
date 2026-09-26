# frozen_string_literal: true

require_relative "plugins_test_helper"

Plugins = Aiconshell::Plugins
JIRA = "https://aiconshell-test.atlassian.net"

def jira_adf_paragraph(text)
  { "type" => "doc", "version" => 1,
    "content" => [{ "type" => "paragraph",
                    "content" => [{ "type" => "text", "text" => text }] }] }
end

def jira_issue(key, updated:, summary: "summary", description: nil, status: "To Do")
  { "id" => "100#{key.hash.abs % 89 + 10}", "key" => key,
    "fields" => { "summary" => summary,
                  "description" => description || jira_adf_paragraph("desc of #{key}"),
                  "status" => { "name" => status },
                  "updated" => updated, "created" => "2026-09-20T10:00:00.000+0000" } }
end

test("jira poll posts Enhanced JQL and pages comments plus changelog") do |registry:, transport:, plugin_env:|
  seen_bodies = []
  transport.stub_proc("POST", "#{JIRA}/rest/api/3/search/jql") do |req|
    body = JSON.parse(req[:body])
    seen_bodies << body
    issues = body["nextPageToken"] ? [] : [jira_issue("PROJ-1", updated: "2026-09-26T12:01:00.000+0000")]
    payload = { "issues" => issues }
    payload["nextPageToken"] = "tok-2" unless body["nextPageToken"]
    Plugins::Http::Response.new(status: 200, headers: {}, body: JSON.generate(payload))
  end
  transport.stub_json("GET", %r{/rest/api/3/issue/PROJ-1/comment}, body: {
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

  expect(seen_bodies[0]["jql"]).to eq('project = PROJ AND updated >= "2026-09-26T11:00:00.000+0000" ORDER BY updated ASC')
  expect(seen_bodies.size).to eq(2)
  expect(seen_bodies[1]["nextPageToken"]).to eq("tok-2")

  ids = out["events"].map { |e| e["event_id"] }
  expect(ids.first(3)).to eq(["jira:issue:PROJ-1", "jira:comment:200", "jira:comment:201"])
  expect(ids[3]).to match(/\Ajira:changelog:\d+:300\z/)
  expect(out["events"][0]["event_type"]).to eq("jira.issue")
  expect(out["events"][1]["payload"]["text"]).to eq("first")
  expect(out["events"][2]["actor_type"]).to eq("bot")
  expect(out["events"][3]["event_type"]).to eq("jira.change")
  expect(out["events"][3]["payload"]["items"]).to eq(["status:To Do->In Progress"])
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T12:04:00.000+0000" })

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
  transport.stub_json("GET", %r{/issue/PROJ-9/comment}, body: { "comments" => [] })
  transport.stub_json("GET", %r{/issue/PROJ-9/changelog}, body: { "values" => [] })

  out = registry.invoke(plugin: "jira", operation: "latest_events",
                        input: { "scope" => "*" }, context: {})

  text = out["events"][0]["payload"]["text"]
  expect(text).to include("Title")
  expect(text).to include("hello @ana")
  expect(text).to include("item")
  # Wildcard scope omits the project clause.
  jql = JSON.parse(transport.requests.first[:body])["jql"]
  expect(jql).to eq("ORDER BY updated ASC")
end

test("jira refuses cross-host nextPage URLs without sending credentials") do |registry:, transport:|
  transport.stub_json("POST", "#{JIRA}/rest/api/3/search/jql",
                      body: { "issues" => [jira_issue("PROJ-1", updated: "2026-09-26T12:01:00Z")] })
  transport.stub_json("GET", %r{/issue/PROJ-1/comment}, body: {
                        "comments" => [],
                        "nextPage" => "https://evil.test/api/comments?token=2"
                      })
  transport.stub_json("GET", %r{/issue/PROJ-1/changelog}, body: { "values" => [] })

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
