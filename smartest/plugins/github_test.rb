# frozen_string_literal: true

require_relative "plugins_test_helper"

Plugins = Aiconshell::Plugins
GH = "https://api.github.com"

def github_token_stub(transport, token: "ghs_test")
  transport.stub_json("POST", "#{GH}/app/installations/789/access_tokens",
                      body: { "token" => token, "expires_at" => "2026-09-26T13:00:00Z" })
end

def github_issue(number, updated:, pr: false, body: "body", title: "title")
  issue = {
    "number" => number, "title" => title, "body" => body, "state" => "open",
    "comments" => 0, "updated_at" => updated,
    "html_url" => "https://github.com/o/r/issues/#{number}",
    "user" => { "login" => "octo", "id" => 1, "type" => "User" }
  }
  issue["pull_request"] = { "url" => "#{GH}/repos/o/r/pulls/#{number}" } if pr
  issue
end

def github_repo_issue_comment(id, issue_number, updated:, body: "nice")
  {
    "id" => id, "body" => body, "updated_at" => updated, "created_at" => updated,
    "html_url" => "https://github.com/o/r/issues/#{issue_number}#c#{id}",
    "issue_url" => "#{GH}/repos/o/r/issues/#{issue_number}",
    "user" => { "login" => "reviewer", "id" => 2, "type" => "User" }
  }
end

def github_repo_review_comment(id, pr_number, updated:, body: "nit", path: "a.rb")
  {
    "id" => id, "body" => body, "path" => path,
    "updated_at" => updated, "created_at" => updated,
    "html_url" => "https://github.com/o/r/pull/#{pr_number}#dc#{id}",
    "pull_request_url" => "#{GH}/repos/o/r/pulls/#{pr_number}",
    "user" => { "login" => "bot", "id" => 3, "type" => "Bot" }
  }
end

def github_empty_lists(transport)
  transport.stub_json("GET", %r{/repos/o/r/issues/comments}, body: [])
  transport.stub_json("GET", %r{/repos/o/r/pulls/comments}, body: [])
  transport.stub_json("GET", %r{/repos/o/r/actions/runs}, body: { "workflow_runs" => [] })
end

test("github poll builds real resource requests with paging") do |registry:, transport:|
  github_token_stub(transport)
  page1 = "#{GH}/repos/o/r/issues?state=all&sort=updated&direction=asc&per_page=100"
  page2 = "#{GH}/repos/o/r/issues?page=2&per_page=100"
  repo_comments_url = "#{GH}/repos/o/r/issues/comments?sort=updated&direction=asc&per_page=100"
  repo_rcomments_url = "#{GH}/repos/o/r/pulls/comments?sort=updated&direction=asc&per_page=100"
  transport.stub_json("GET", page1,
                      body: [github_issue(1, updated: "2026-09-26T12:01:00Z", body: "issue one"),
                             github_issue(2, updated: "2026-09-26T12:02:00Z", pr: true,
                                          body: "pr two")],
                      headers: { "Link" => %(<#{page2}>; rel="next") })
  transport.stub_json("GET", page2, body: [github_issue(3, updated: "2026-09-26T12:03:00Z")])
  transport.stub_json("GET", repo_comments_url, body: [
                        github_repo_issue_comment(101, 1, updated: "2026-09-26T12:04:00Z")
                      ])
  transport.stub_json("GET", "#{GH}/repos/o/r/pulls/2/reviews?per_page=100", body: [
                        { "id" => 201, "state" => "APPROVED", "body" => "lgtm",
                          "submitted_at" => "2026-09-26T12:05:00Z",
                          "html_url" => "https://github.com/o/r/pull/2#r201",
                          "user" => { "login" => "reviewer", "type" => "User" } }
                      ])
  transport.stub_json("GET", repo_rcomments_url, body: [
                        github_repo_review_comment(301, 2, updated: "2026-09-26T12:06:00Z")
                      ])
  transport.stub_json("GET", %r{/repos/o/r/actions/runs}, body: {
                        "workflow_runs" => [
                          { "id" => 401, "name" => "ci", "status" => "completed",
                            "conclusion" => "success", "head_sha" => "abc",
                            "created_at" => "2026-09-26T12:06:30Z",
                            "updated_at" => "2026-09-26T12:07:00Z",
                            "html_url" => "https://github.com/o/r/actions/runs/401",
                            "actor" => { "login" => "octo", "type" => "User" } }
                        ]
                      })

  out = registry.invoke(plugin: "github", operation: "latest_events",
                        input: { "scope" => "o/r" }, context: {})

  ids = out["events"].map { |e| e["event_id"] }
  expect(ids).to eq([
                      "github:issue:o/r#1", "github:issue:o/r#2", "github:issue:o/r#3",
                      "github:issue_comment:101", "github:review:201",
                      "github:review_comment:301", "github:workflow_run:401"
                    ])
  expect(out["events"].map { |e| e["occurred_at"] }.sort)
    .to eq(out["events"].map { |e| e["occurred_at"] })
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T12:07:00Z" })
  expect(JSON.parse(JSON.generate(out["cursor"]))).to eq(out["cursor"])

  by_id = out["events"].to_h { |e| [e["event_id"], e] }
  expect(by_id["github:issue:o/r#1"]["resource_id"]).to eq("issue:o/r#1")
  expect(by_id["github:issue:o/r#2"]["resource_id"]).to eq("pr:o/r#2")
  expect(by_id["github:issue_comment:101"]["resource_id"]).to eq("issue:o/r#1")
  expect(by_id["github:review:201"]["resource_id"]).to eq("pr:o/r#2")
  expect(by_id["github:issue:o/r#1"]["payload"]["body"]).to eq("issue one")
  expect(by_id["github:issue:o/r#2"]["payload"]["body"]).to eq("pr two")
  expect(by_id["github:issue_comment:101"]["payload"]["body"]).to eq("nice")
  expect(by_id["github:review:201"]["payload"]["body"]).to eq("lgtm")
  expect(by_id["github:review_comment:301"]["payload"]["body"]).to eq("nit")

  bot_comment = by_id["github:review_comment:301"]
  expect(bot_comment["actor_type"]).to eq("bot")
  expect(bot_comment["resource_id"]).to eq("pr:o/r#2")

  # Real request shapes: paged issues, repository-level comments, PR-only reviews.
  expect(transport.requests_to(page1).size).to eq(1)
  expect(transport.requests_to(page2).size).to eq(1)
  expect(transport.requests_to(repo_comments_url).size).to eq(1)
  expect(transport.requests_to(repo_rcomments_url).size).to eq(1)
  expect(transport.requests_to(%r{/repos/o/r/issues/\d+/comments}).size).to eq(0)
  expect(transport.requests_to(%r{/repos/o/r/issues/\d+$}).size).to eq(0)
  expect(transport.requests_to(%r{/pulls/1/}).size).to eq(0)
  expect(transport.requests_to(%r{/pulls/2/reviews}).size).to eq(1)
  api_calls = transport.requests.reject { |r| r[:url].include?("/access_tokens") }
  expect(api_calls.map { |r| r[:headers]["Authorization"] }.uniq).to eq(["Bearer ghs_test"])
end

test("github poll mints a verifiable RS256 app JWT for the token exchange") do |registry:, transport:, plugin_env:|
  github_token_stub(transport)
  transport.stub_json("GET", %r{/repos/o/r/issues}, body: [])
  transport.stub_json("GET", %r{/repos/o/r/pulls/comments}, body: [])
  transport.stub_json("GET", %r{/repos/o/r/actions/runs}, body: { "workflow_runs" => [] })

  registry.invoke(plugin: "github", operation: "latest_events",
                  input: { "scope" => "o/r" }, context: {})

  token_req = transport.requests_to(%r{/access_tokens}).first
  jwt = token_req[:headers]["Authorization"].sub("Bearer ", "")
  header_b64, payload_b64, sig_b64 = jwt.split(".")
  expect(header_b64.nil?).to eq(false)
  key = OpenSSL::PKey::RSA.new(plugin_env["GITHUB_PRIVATE_KEY"])
  signed = "#{header_b64}.#{payload_b64}"
  verified = key.verify(OpenSSL::Digest::SHA256.new,
                        Base64.urlsafe_decode64(sig_b64), signed)
  expect(verified).to eq(true)
  payload = JSON.parse(Base64.urlsafe_decode64(payload_b64))
  expect(payload["iss"]).to eq("123456")
  expect(payload["exp"] - payload["iat"]).to eq(600)
end

test("github poll sends since filters with overlap and skips stale items") do |registry:, transport:|
  github_token_stub(transport)
  transport.stub_proc("GET", %r{/repos/o/r/issues\?}) do |req|
    expect(req[:url]).to match(/since=2026-09-26T10%3A59%3A00Z/)
    Plugins::Http::Response.new(status: 200, headers: {},
                                body: JSON.generate([
                                                      github_issue(9, updated: "2026-09-26T10:00:00Z"),
                                                      github_issue(10, updated: "2026-09-26T12:30:00Z")
                                                    ]))
  end
  transport.stub_proc("GET", %r{/repos/o/r/issues/comments}) do |req|
    expect(req[:url]).to match(/since=2026-09-26T10%3A59%3A00Z/)
    Plugins::Http::Response.new(status: 200, headers: {}, body: "[]")
  end
  transport.stub_json("GET", %r{/repos/o/r/pulls/comments}, body: [])
  transport.stub_json("GET", %r{/repos/o/r/actions/runs}, body: { "workflow_runs" => [] })

  out = registry.invoke(plugin: "github", operation: "latest_events",
                        input: { "scope" => "o/r",
                                 "cursor" => { "since" => "2026-09-26T11:00:00Z" } },
                        context: {})

  expect(out["events"].map { |e| e["event_id"] }).to eq(["github:issue:o/r#10"])
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T12:30:00Z" })
end

test("github emits events at equal timestamps instead of skipping") do |registry:, transport:|
  github_token_stub(transport)
  transport.stub_json("GET", %r{/repos/o/r/issues\?},
                      body: [github_issue(22, updated: "2026-09-26T11:00:00+00:00")])
  github_empty_lists(transport)

  out = registry.invoke(plugin: "github", operation: "latest_events",
                        input: { "scope" => "o/r",
                                 "cursor" => { "since" => "2026-09-26T11:00:00Z" } },
                        context: {})

  expect(out["events"].map { |e| e["event_id"] }).to eq(["github:issue:o/r#22"])
  expect(out["events"][0]["occurred_at"]).to eq("2026-09-26T11:00:00Z")
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T11:00:00Z" })
end

test("github orders events by UTC instant and normalizes occurred_at") do |registry:, transport:|
  github_token_stub(transport)
  transport.stub_json("GET", %r{/repos/o/r/issues\?}, body: [
                        github_issue(21, updated: "2026-09-26T11:30:00Z"),
                        github_issue(20, updated: "2026-09-26T20:00:00+09:00")
                      ])
  github_empty_lists(transport)

  out = registry.invoke(plugin: "github", operation: "latest_events",
                        input: { "scope" => "o/r",
                                 "cursor" => { "since" => "2026-09-26T10:00:00Z" } },
                        context: {})

  expect(out["events"].map { |e| e["event_id"] })
    .to eq(["github:issue:o/r#20", "github:issue:o/r#21"])
  expect(out["events"].map { |e| e["occurred_at"] })
    .to eq(["2026-09-26T11:00:00Z", "2026-09-26T11:30:00Z"])
end

test("github polls repository comments independently for old issues") do |registry:, transport:|
  github_token_stub(transport)
  transport.stub_json("GET", %r{/repos/o/r/issues\?}, body: [])
  transport.stub_json("GET", %r{/repos/o/r/issues/comments}, body: [
                        github_repo_issue_comment(901, 99, updated: "2026-09-26T12:10:00Z",
                                                             body: "late comment"),
                        github_repo_issue_comment(902, 100, updated: "2026-09-26T12:11:00Z",
                                                              body: "pr note")
                      ])
  transport.stub_json("GET", "#{GH}/repos/o/r/issues/99",
                      body: github_issue(99, updated: "2026-09-01T00:00:00Z"))
  transport.stub_json("GET", "#{GH}/repos/o/r/issues/100",
                      body: github_issue(100, updated: "2026-09-01T00:00:00Z", pr: true))
  transport.stub_json("GET", %r{/repos/o/r/pulls/comments}, body: [
                        github_repo_review_comment(903, 101, updated: "2026-09-26T12:12:00Z")
                      ])
  transport.stub_json("GET", %r{/repos/o/r/actions/runs}, body: { "workflow_runs" => [] })

  out = registry.invoke(plugin: "github", operation: "latest_events",
                        input: { "scope" => "o/r",
                                 "cursor" => { "since" => "2026-09-26T12:00:00Z" } },
                        context: {})

  by_id = out["events"].to_h { |e| [e["event_id"], e] }
  expect(by_id.keys.sort).to eq(%w[github:issue_comment:901 github:issue_comment:902
                                   github:review_comment:903])
  expect(by_id["github:issue_comment:901"]["resource_id"]).to eq("issue:o/r#99")
  expect(by_id["github:issue_comment:901"]["payload"]["body"]).to eq("late comment")
  expect(by_id["github:issue_comment:902"]["resource_id"]).to eq("pr:o/r#100")
  expect(by_id["github:review_comment:903"]["resource_id"]).to eq("pr:o/r#101")
  expect(out["cursor"]).to eq({ "since" => "2026-09-26T12:12:00Z" })
  expect(transport.requests_to("#{GH}/repos/o/r/issues/99").size).to eq(1)
  expect(transport.requests_to("#{GH}/repos/o/r/issues/100").size).to eq(1)
end

test("github edit keeps event_id but changes fingerprint") do |registry:, transport:|
  github_token_stub(transport)
  bodies = ["original", "edited"]
  transport.stub_proc("GET", %r{/repos/o/r/issues\?}) do |_req|
    Plugins::Http::Response.new(status: 200, headers: {},
                                body: JSON.generate([github_issue(1, updated: "2026-09-26T12:01:00Z",
                                                                             body: bodies.shift || "edited")]))
  end
  transport.stub_json("GET", %r{/repos/o/r/issues/comments}, body: [])
  transport.stub_json("GET", %r{/repos/o/r/pulls/comments}, body: [])
  transport.stub_json("GET", %r{/actions/runs}, body: { "workflow_runs" => [] })

  first = registry.invoke(plugin: "github", operation: "latest_events",
                          input: { "scope" => "o/r" }, context: {})
  second = registry.invoke(plugin: "github", operation: "latest_events",
                           input: { "scope" => "o/r",
                                    "cursor" => { "since" => "2026-09-26T12:00:00Z" } },
                           context: {})

  expect(first["events"].size).to eq(1)
  expect(second["events"].size).to eq(1)
  expect(second["events"][0]["event_id"]).to eq(first["events"][0]["event_id"])
  expect(second["events"][0]["fingerprint"]).not_to eq(first["events"][0]["fingerprint"])
end

test("github page failure raises without advancing the cursor") do |registry:, transport:|
  github_token_stub(transport)
  page1 = "#{GH}/repos/o/r/issues?state=all&sort=updated&direction=asc&per_page=100"
  transport.stub_json("GET", page1,
                      body: [github_issue(1, updated: "2026-09-26T12:01:00Z")],
                      headers: { "Link" => %(<#{GH}/repos/o/r/issues?page=2>; rel="next") })
  transport.stub_json("GET", "#{GH}/repos/o/r/issues?page=2", status: 500, body: "boom")

  expect do
    registry.invoke(plugin: "github", operation: "latest_events",
                    input: { "scope" => "o/r" }, context: {})
  end.to raise_error(Plugins::HttpError, /HTTP 500/)
  # Failed before repository comment polling: the raise means the caller
  # keeps its old cursor.
  expect(transport.requests_to(%r{/issues/comments}).size).to eq(0)
end

test("github raises IncompletePoll when a listing exceeds its page bound") do |registry:, transport:|
  github_token_stub(transport)
  transport.stub_json("GET", %r{/repos/o/r/issues\?}, body: [])
  transport.stub_json("GET", %r{/repos/o/r/issues/comments}, body: [])
  transport.stub_json("GET", %r{/repos/o/r/pulls/comments}, body: [])
  runs1 = "#{GH}/repos/o/r/actions/runs?per_page=100"
  runs2 = "#{GH}/repos/o/r/actions/runs?per_page=100&page=2"
  runs3 = "#{GH}/repos/o/r/actions/runs?per_page=100&page=3"
  runs4 = "#{GH}/repos/o/r/actions/runs?per_page=100&page=4"
  transport.stub_json("GET", runs1, body: { "workflow_runs" => [] },
                      headers: { "Link" => %(<#{runs2}>; rel="next") })
  transport.stub_json("GET", runs2, body: { "workflow_runs" => [] },
                      headers: { "Link" => %(<#{runs3}>; rel="next") })
  transport.stub_json("GET", runs3, body: { "workflow_runs" => [] },
                      headers: { "Link" => %(<#{runs4}>; rel="next") })
  expect do
    registry.invoke(plugin: "github", operation: "latest_events",
                    input: { "scope" => "o/r" }, context: {})
  end.to raise_error(Plugins::IncompletePoll, /workflow runs pagination exceeded 3 pages/)
  expect(transport.requests_to(runs4).size).to eq(0)
end

test("github raises IncompletePoll when issues exceed the expansion bound") do |registry:, transport:|
  github_token_stub(transport)
  many = (1..51).map { |n| github_issue(n, updated: "2026-09-26T12:01:00Z") }
  transport.stub_json("GET", %r{/repos/o/r/issues\?}, body: many)

  expect do
    registry.invoke(plugin: "github", operation: "latest_events",
                    input: { "scope" => "o/r" }, context: {})
  end.to raise_error(Plugins::IncompletePoll, /exceeded 50 items/)
  expect(transport.requests_to(%r{/issues/comments}).size).to eq(0)
end

test("github refuses cross-host next links and cursor URLs") do |registry:, transport:|
  github_token_stub(transport)
  page1 = "#{GH}/repos/o/r/issues?state=all&sort=updated&direction=asc&per_page=100"
  transport.stub_json("GET", page1, body: [],
                      headers: { "Link" => '<https://evil.test/steal>; rel="next"' })
  expect do
    registry.invoke(plugin: "github", operation: "latest_events",
                    input: { "scope" => "o/r" }, context: {})
  end.to raise_error(Plugins::HostRejected, /evil\.test/)
  expect(transport.requests_to(%r{evil\.test}).size).to eq(0)

  transport.requests.clear
  expect do
    registry.invoke(plugin: "github", operation: "latest_events",
                    input: { "scope" => "o/r",
                             "cursor" => { "next" => "https://evil.test/resume" } },
                    context: {})
  end.to raise_error(Plugins::HostRejected, /evil\.test/)
  expect(transport.requests).to eq([])
end

test("github validates cursor shape and time strictly") do |registry:, transport:|
  github_token_stub(transport)
  invalid_cursors = [
    { "since" => "not-a-time" },
    { "since" => "" },
    { "since" => 123 },
    { "since" => "2026-13-45T99:99:99Z" },
    { "bogus" => "x" },
    { "since" => "2026-09-26T11:00:00Z", "extra" => 1 },
    { "next" => "not a url" },
    { "next" => "" },
    { "next" => 123 }
  ]
  invalid_cursors.each do |cursor|
    expect do
      registry.invoke(plugin: "github", operation: "latest_events",
                      input: { "scope" => "o/r", "cursor" => cursor }, context: {})
    end.to raise_error(Plugins::InputInvalid, /cursor/)
    expect(transport.requests).to eq([])
    transport.requests.clear
  end
end

test("github surfaces rate limits with retry_after") do |registry:, transport:|
  github_token_stub(transport)
  transport.stub_json("GET", %r{/repos/o/r/issues}, status: 429,
                      body: { "message" => "slow down" },
                      headers: { "Retry-After" => "42" })
  begin
    registry.invoke(plugin: "github", operation: "latest_events",
                    input: { "scope" => "o/r" }, context: {})
    raise "expected RateLimited"
  rescue Plugins::RateLimited => e
    expect(e.retry_after).to eq(42)
  end
end

test("github reply and create_issue post real requests") do |registry:, transport:|
  github_token_stub(transport)
  transport.stub_json("POST", "#{GH}/repos/o/r/issues/12/comments", status: 201,
                      body: { "id" => 55, "html_url" => "https://github.com/o/r/issues/12#c55" })
  out = registry.invoke(plugin: "github", operation: "reply",
                        input: { "resource_id" => "pr:o/r#12", "body" => "looks good" },
                        context: {})
  expect(out).to eq({ "external_id" => "55",
                      "url" => "https://github.com/o/r/issues/12#c55" })
  req = transport.requests_to("#{GH}/repos/o/r/issues/12/comments").first
  expect(JSON.parse(req[:body])).to eq({ "body" => "looks good" })
  expect(req[:headers]["Authorization"]).to eq("Bearer ghs_test")
  expect(req[:headers]["X-GitHub-Api-Version"]).to eq("2022-11-28")

  transport.stub_json("POST", "#{GH}/repos/o/r/issues", status: 201,
                      body: { "number" => 77, "html_url" => "https://github.com/o/r/issues/77" })
  out = registry.invoke(plugin: "github", operation: "create_issue",
                        input: { "scope" => "o/r", "title" => "bug", "body" => "details" },
                        context: {})
  expect(out["external_id"]).to eq("77")
  req = transport.requests_to("#{GH}/repos/o/r/issues").first
  expect(JSON.parse(req[:body])).to eq({ "title" => "bug", "body" => "details" })

  expect do
    registry.invoke(plugin: "github", operation: "reply",
                    input: { "resource_id" => "commit:abc", "body" => "x" }, context: {})
  end.to raise_error(Plugins::InputInvalid, /resource_id/)
end

test("github credentials are required before any I/O") do |registry:, transport:, plugin_env:|
  plugin_env.delete("GITHUB_PRIVATE_KEY")
  expect do
    registry.invoke(plugin: "github", operation: "latest_events",
                    input: { "scope" => "o/r" }, context: {})
  end.to raise_error(Plugins::CredentialsMissing, /GITHUB_PRIVATE_KEY/)
  expect(transport.requests).to eq([])

  plugin_env["GITHUB_PRIVATE_KEY"] = "not-a-pem-key"
  expect do
    registry.invoke(plugin: "github", operation: "reply",
                    input: { "resource_id" => "issue:o/r#1", "body" => "hi" }, context: {})
  end.to raise_error(Plugins::CredentialsMissing, /unparsable/)
  expect(transport.requests).to eq([])
end

test("github installation token is cached until expiry") do |registry:, transport:, clock:|
  github_token_stub(transport)
  transport.stub_json("GET", %r{/repos/o/r/issues}, body: [])
  transport.stub_json("GET", %r{/repos/o/r/pulls/comments}, body: [])
  transport.stub_json("GET", %r{/repos/o/r/actions/runs}, body: { "workflow_runs" => [] })

  2.times do
    registry.invoke(plugin: "github", operation: "latest_events",
                    input: { "scope" => "o/r" }, context: {})
  end
  expect(transport.requests_to(%r{/access_tokens}).size).to eq(1)

  clock.advance(3600)
  registry.invoke(plugin: "github", operation: "latest_events",
                  input: { "scope" => "o/r" }, context: {})
  expect(transport.requests_to(%r{/access_tokens}).size).to eq(2)
end
