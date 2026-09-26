# frozen_string_literal: true

require_relative "plugins_test_helper"

Plugins = Aiconshell::Plugins
GH_LIST = "https://api.github.com"
GH_LIST_URL = "#{GH_LIST}/repos/o/r/issues?state=open&sort=created&direction=desc&per_page=30&page=1"

def list_token_stub(transport)
  transport.stub_json("POST", "#{GH_LIST}/app/installations/789/access_tokens",
                      body: { "token" => "ghs_test", "expires_at" => "2026-09-26T13:00:00Z" })
end

def list_issue_raw(id, number, title: "title", body: "body", labels: [], state: "open", pr: false)
  raw = {
    "id" => id, "number" => number, "title" => title, "body" => body,
    "state" => state, "labels" => labels.map { |name| { "name" => name } },
    "html_url" => "https://github.com/o/r/issues/#{number}"
  }
  raw["pull_request"] = { "url" => "#{GH_LIST}/repos/o/r/pulls/#{number}" } if pr
  raw
end

test("catalog marks latest_events and list_issues read_only, writes false by default") do |registry:|
  by_id = registry.catalog.to_h { |entry| [entry["id"], entry] }
  github = by_id["github"]["operations"].to_h { |op| [op["name"], op] }

  expect(github["latest_events"]["read_only"]).to eq(true)
  expect(github["list_issues"]["read_only"]).to eq(true)
  expect(github["reply"]["read_only"]).to eq(false)
  expect(github["create_issue"]["read_only"]).to eq(false)
  expect(by_id["jira"]["operations"].find { |op| op["name"] == "latest_events" }["read_only"]).to eq(true)
  expect(by_id["teams"]["operations"].find { |op| op["name"] == "latest_events" }["read_only"]).to eq(true)
  expect(by_id["teams"]["operations"].find { |op| op["name"] == "send_message" }["read_only"]).to eq(false)

  registry.catalog.each do |entry|
    entry["operations"].each do |op|
      expect([true, false].include?(op["read_only"])).to eq(true)
    end
  end
end

test("list_issues excludes pull requests and normalizes open data") do |registry:, transport:|
  list_token_stub(transport)
  transport.stub_json("GET", GH_LIST_URL, body: [
    list_issue_raw(1001, 7, title: "High priority bug", body: "details here", labels: %w[bug urgent]),
    list_issue_raw(1002, 8, title: "A PR", pr: true),
    { "id" => 1003, "number" => 9, "title" => "Null body", "body" => nil,
      "state" => "open", "labels" => [{ "name" => "docs" }],
      "html_url" => "https://github.com/o/r/issues/9" }
  ])

  out = registry.invoke(plugin: "github", operation: "list_issues",
                        input: { "scope" => "o/r" }, context: {})

  expect(out["complete"]).to eq(true)
  expect(out["next_cursor"]).to eq(nil)
  expect(out["truncated"]).to eq(false)
  expect(out["issues"].size).to eq(2)
  first = out["issues"][0]
  expect(first).to eq({
    "id" => 1001, "number" => 7, "title" => "High priority bug",
    "title_truncated" => false, "body" => "details here", "body_truncated" => false,
    "labels" => %w[bug urgent], "labels_truncated" => false,
    "state" => "open", "url" => "https://github.com/o/r/issues/7", "url_truncated" => false
  })
  expect(out["issues"][1]["body"]).to eq("")
  expect(out["issues"][1]["body_truncated"]).to eq(false)
  expect(transport.requests_to(GH_LIST_URL).size).to eq(1)
end

test("list_issues truncates long bodies with explicit flags") do |registry:, transport:|
  list_token_stub(transport)
  long_body = "b" * 2500
  long_title = "t" * 400
  labels = (1..12).map { |n| "label-#{n}" }
  labels[0] = "x" * 150
  transport.stub_json("GET", GH_LIST_URL, body: [
    list_issue_raw(2001, 11, title: long_title, body: long_body, labels: labels)
  ])

  out = registry.invoke(plugin: "github", operation: "list_issues",
                        input: { "scope" => "o/r" }, context: {})

  issue = out["issues"][0]
  expect(issue["body"].length).to eq(2000)
  expect(issue["body_truncated"]).to eq(true)
  expect(issue["title"].length).to eq(300)
  expect(issue["title_truncated"]).to eq(true)
  expect(issue["labels"].length).to eq(10)
  expect(issue["labels_truncated"]).to eq(true)
  expect(issue["labels"][0].length).to eq(100)
  expect(out["truncated"]).to eq(true)
  expect(out["complete"]).to eq(true)
end

test("list_issues follows one continuation page and never claims complete when partial") do |registry:, transport:|
  list_token_stub(transport)
  page1 = GH_LIST_URL
  page2 = page1.sub("page=1", "page=2")
  transport.stub_json("GET", page1,
                      body: [list_issue_raw(3001, 21)],
                      headers: { "Link" => %(<#{page2}>; rel="next") })
  transport.stub_json("GET", page2, body: [list_issue_raw(3002, 22)])

  first = registry.invoke(plugin: "github", operation: "list_issues",
                          input: { "scope" => "o/r" }, context: {})
  expect(first["complete"]).to eq(false)
  expect(first["issues"].size).to eq(1)
  expect(first["next_cursor"]).to eq({ "version" => 1, "scope" => "o/r", "page" => 2 })

  second = registry.invoke(plugin: "github", operation: "list_issues",
                           input: { "scope" => "o/r", "cursor" => first["next_cursor"] },
                           context: {})
  expect(second["complete"]).to eq(true)
  expect(second["next_cursor"]).to eq(nil)
  expect(second["issues"].map { |issue| issue["number"] }).to eq([22])
  expect(transport.requests_to(page1).size).to eq(1)
  expect(transport.requests_to(page2).size).to eq(1)
end

test("list_issues rejects unsafe scopes before auth or network") do |registry:, transport:|
  [".", "..", "o/.", "o/..", "o/r ", " o/r", "o//r", "o/r#", "o*r", "o/r?x=1", "o%2Fr", "o/r%00", ""].each do |scope|
    expect do
      registry.invoke(plugin: "github", operation: "list_issues",
                      input: { "scope" => scope }, context: {})
    end.to raise_error(Plugins::InputInvalid)
  end
  expect(transport.requests).to eq([])
end

test("list_issues rejects foreign or mismatched cursors before token I/O") do |registry:, transport:|
  bad = [
    { "version" => 1, "scope" => "other/repo", "page" => 2 },
    { "version" => 2, "scope" => "o/r", "page" => 2 },
    { "version" => 1, "scope" => "o/r", "page" => 1 },
    { "version" => 1, "scope" => "o/r", "page" => 101 },
    { "version" => 1, "scope" => "o/r", "page" => "2" },
    { "version" => 1, "scope" => "o/r", "page" => 2, "extra" => true },
    { "next" => "https://evil.test/x" }
  ]
  bad.each do |cursor|
    expect do
      registry.invoke(plugin: "github", operation: "list_issues",
                      input: { "scope" => "o/r", "cursor" => cursor }, context: {})
    end.to raise_error(Plugins::InputInvalid, /cursor/)
  end
  expect(transport.requests).to eq([])
end

test("list_issues rejects cross-host Link targets without following") do |registry:, transport:|
  list_token_stub(transport)
  evil = "https://evil.test/repos/o/r/issues?state=open&sort=created&direction=desc&per_page=30&page=2"
  transport.stub_json("GET", GH_LIST_URL, body: [],
                      headers: { "Link" => %(<#{evil}>; rel="next") })
  expect do
    registry.invoke(plugin: "github", operation: "list_issues",
                    input: { "scope" => "o/r" }, context: {})
  end.to raise_error(Plugins::HostRejected)
  expect(transport.requests_to(%r{evil\.test}).size).to eq(0)
end

test("list_issues rejects off-query Link targets without following") do |registry:, transport:, clock:, plugin_env:|
  fresh_transport = FakeTransport.new(clock: clock)
  fresh = Plugins::Registry.new(env: plugin_env, transport: fresh_transport, clock: clock)
  fresh.register(Plugins::Github.new)
  list_token_stub(fresh_transport)
  wrong = GH_LIST_URL.sub("per_page=30", "per_page=100").sub("page=1", "page=2")
  fresh_transport.stub_json("GET", GH_LIST_URL, body: [],
                            headers: { "Link" => %(<#{wrong}>; rel="next") })
  expect do
    fresh.invoke(plugin: "github", operation: "list_issues",
                 input: { "scope" => "o/r" }, context: {})
  end.to raise_error(Plugins::OutputInvalid, /repository, stream, filters/)
  expect(fresh_transport.requests_to(%r{page=2}).size).to eq(0)
end

test("list_issues enforces operation scope and input schema before I/O") do |registry:, transport:|
  expect do
    registry.invoke(plugin: "github", operation: "list_issues",
                    input: { "scope" => "o/r" },
                    context: { "scopes" => ["github:write"] })
  end.to raise_error(Plugins::PermissionDenied, /github:read/)
  expect(transport.requests).to eq([])

  expect do
    registry.invoke(plugin: "github", operation: "list_issues",
                    input: { "scope" => "o/r", "extra" => 1 }, context: {})
  end.to raise_error(Plugins::InputInvalid)
  expect(transport.requests).to eq([])
end

{ "ASCII" => "a", "Japanese" => "あ", "emoji" => "😀", "JSON escaping" => "\u0000" }.each do |name, fill|
  test("list_issues full #{name} page fits the serialized query byte budget") do |registry:, transport:|
    list_token_stub(transport)
    issues = Array.new(30) do
      { "id" => 9223372036854775807, "number" => 2147483647,
        "title" => fill * 400, "body" => fill * 2100,
        "state" => "open", "labels" => Array.new(10) { { "name" => fill * 110 } },
        "html_url" => "https://github.com/" + ("u" * 490) }
    end
    transport.stub_json("GET", GH_LIST_URL, body: issues)
    out = registry.invoke(plugin: "github", operation: "list_issues", input: { "scope" => "o/r" }, context: {})
    expect(out["issues"].size).to eq(30)
    expect(JSON.generate(out).bytesize < 128_000).to eq(true)
    expect(out["truncated"]).to eq(true)
    expect(out["issues"].all? { |issue| issue["body_truncated"] && issue["title_truncated"] && issue["labels_truncated"] }).to eq(true)
    expect(out["issues"].all? { |issue| JSON.generate(issue["body"]).bytesize - 2 <= 2000 }).to eq(true)
  end
end

test("list_issues final bounded page explicitly reports an unusable continuation") do |registry:, transport:|
  list_token_stub(transport)
  last = GH_LIST_URL.sub("page=1", "page=100")
  beyond = GH_LIST_URL.sub("page=1", "page=101")
  transport.stub_json("GET", last, body: [list_issue_raw(1, 1)], headers: { "Link" => %(<#{beyond}>; rel="next") })
  out = registry.invoke(plugin: "github", operation: "list_issues",
    input: { "scope" => "o/r", "cursor" => { "version" => 1, "scope" => "o/r", "page" => 100 } })
  expect(out["issues"].size).to eq(1)
  expect(out["complete"]).to eq(false)
  expect(out["next_cursor"]).to eq(nil)
  expect(out["limit_reached"]).to eq(true)
  expect(Plugins::Schemas.valid?(Plugins::Schemas::LIST_ISSUES_OUTPUT, out)).to eq(true)
  expect(transport.requests_to(beyond)).to eq([])
end
