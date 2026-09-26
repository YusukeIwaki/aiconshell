# frozen_string_literal: true

require_relative "plugins_test_helper"

Plugins = Aiconshell::Plugins
GH = "https://api.github.com"
GH_STREAM_URLS = {
  "issues" => "#{GH}/repos/o/r/issues?state=all&sort=updated&direction=desc&per_page=25",
  "issue_comments" => "#{GH}/repos/o/r/issues/comments?sort=updated&direction=desc&per_page=100",
  "review_comments" => "#{GH}/repos/o/r/pulls/comments?sort=updated&direction=desc&per_page=100",
  "workflow_runs" => "#{GH}/repos/o/r/actions/runs?per_page=100"
}.freeze

def github_cursor(since: nil, next_urls: {}, completed_at: nil)
  { "version" => 2, "scope" => "o/r", "since" => since,
    "streams" => GH_STREAM_URLS.keys.to_h do |name|
      [name, { "next" => next_urls[name], "completed_at" => completed_at }]
    end }
end

def github_run(id, updated:, created: "2026-01-01T00:00:00Z", attempt: 1)
  { "id" => id, "name" => "ci", "status" => "completed", "conclusion" => "success",
    "head_sha" => "abc", "created_at" => created, "updated_at" => updated, "run_attempt" => attempt,
    "html_url" => "https://github.com/o/r/actions/runs/#{id}",
    "actor" => { "login" => "octo", "type" => "User" } }
end

def github_paged_stream(transport, name, records, page_size:, since: nil)
  first = GH_STREAM_URLS.fetch(name)
  first += "&since=#{URI.encode_www_form_component((Time.iso8601(since) - 60).iso8601)}" if since && %w[issue_comments review_comments].include?(name)
  path = URI.parse(first).path
  transport.stub_proc("GET", %r{\A#{Regexp.escape(GH + path)}\?}) do |request|
    page = URI.decode_www_form(URI.parse(request[:url]).query).to_h.fetch("page", "1").to_i
    current = records.respond_to?(:call) ? records.call : records
    values = current.slice((page - 1) * page_size, page_size) || []
    headers = {}
    headers["Link"] = %(<#{first}&page=#{page + 1}>; rel="next") if page * page_size < current.length
    body = name == "workflow_runs" ? { "workflow_runs" => values } : values
    Plugins::Http::Response.new(status: 200, headers: headers, body: JSON.generate(body))
  end
end

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
  page1 = GH_STREAM_URLS["issues"]
  page2 = "#{page1}&page=2"
  repo_comments_url = GH_STREAM_URLS["issue_comments"]
  repo_rcomments_url = GH_STREAM_URLS["review_comments"]
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
  expect(out["cursor"]).to eq(github_cursor(completed_at: "2026-09-26T12:00:00Z"))
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

test("github poll filters comments with overlap and applies the initial floor to issue snapshots") do |registry:, transport:|
  github_token_stub(transport)
  transport.stub_proc("GET", %r{/repos/o/r/issues\?}) do |req|
    expect(req[:url]).to eq(GH_STREAM_URLS["issues"])
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
  expect(out["cursor"]).to eq(github_cursor(since: "2026-09-26T11:00:00Z", completed_at: "2026-09-26T12:00:00Z"))
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
  expect(out["cursor"]).to eq(github_cursor(since: "2026-09-26T11:00:00Z", completed_at: "2026-09-26T12:00:00Z"))
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
  expect(out["cursor"]).to eq(github_cursor(since: "2026-09-26T12:00:00Z", completed_at: "2026-09-26T12:00:00Z"))
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
  page1 = GH_STREAM_URLS["issues"]
  transport.stub_json("GET", page1,
                      body: [github_issue(1, updated: "2026-09-26T12:01:00Z")],
                      headers: { "Link" => %(<#{page1}&page=2>; rel="next") })
  transport.stub_json("GET", "#{page1}&page=2", status: 500, body: "boom")

  expect do
    registry.invoke(plugin: "github", operation: "latest_events",
                    input: { "scope" => "o/r" }, context: {})
  end.to raise_error(Plugins::HttpError, /HTTP 500/)
  # Failed before repository comment polling: the raise means the caller
  # keeps its old cursor.
  expect(transport.requests_to(%r{/issues/comments}).size).to eq(0)
end

test("github checkpoints workflow history beyond three hundred runs and checks the head again") do |registry:, transport:|
  github_token_stub(transport)
  transport.stub_json("GET", %r{/repos/o/r/issues\?}, body: [])
  transport.stub_json("GET", %r{/repos/o/r/issues/comments}, body: [])
  transport.stub_json("GET", %r{/repos/o/r/pulls/comments}, body: [])
  runs = 301.downto(1).map { |id| github_run(id, updated: "2026-01-01T00:00:00Z") }
  github_paged_stream(transport, "workflow_runs", runs, page_size: 100)
  first = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r" })
  expect(first["events"].size).to eq(300)
  expect(first["cursor"]["streams"]["workflow_runs"]).to eq({
    "next" => "#{GH_STREAM_URLS['workflow_runs']}&page=4", "completed_at" => nil
  })
  expect(transport.requests_to(%r{/actions/runs}).size).to eq(3)

  transport.requests.clear
  second = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => first["cursor"] })
  expect(second["events"].size).to eq(101)
  expect((first["events"] + second["events"]).map { |event| event["event_id"] }.uniq.size).to eq(301)
  expect(second["cursor"]["streams"]["workflow_runs"]).to eq({ "next" => nil, "completed_at" => "2026-09-26T12:00:00Z" })
  expect(transport.requests_to(GH_STREAM_URLS["workflow_runs"]).size).to eq(1)
  expect(transport.requests_to(%r{/actions/runs}).size).to eq(2)
end

test("github advances through more than fifty historical PRs with bounded review expansion") do |registry:, transport:|
  github_token_stub(transport)
  many = 51.downto(1).map { |n| github_issue(n, updated: "2026-01-01T00:00:00Z", pr: true) }
  github_paged_stream(transport, "issues", many, page_size: 25)
  github_empty_lists(transport)
  transport.stub_json("GET", %r{/pulls/\d+/reviews\?}, body: [])

  first = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r" })
  expect(first["events"].size).to eq(50)
  expect(first["cursor"]["streams"]["issues"]).to eq({ "next" => "#{GH_STREAM_URLS['issues']}&page=3", "completed_at" => nil })
  expect(transport.requests_to(%r{/pulls/\d+/reviews\?}).size).to eq(50)
  transport.requests.clear
  second = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => first["cursor"] })
  expect(second["events"].size).to eq(26)
  expect((first["events"] + second["events"]).map { |event| event["event_id"] }.uniq.size).to eq(51)
  expect(transport.requests_to(GH_STREAM_URLS["issues"]).size).to eq(1)
  expect(transport.requests_to(%r{/pulls/\d+/reviews\?}).size).to eq(26)
  expect(second["cursor"]["streams"]["issues"]["next"]).to eq(nil)
end

test("github streams keep independent bounded sweep positions") do |registry:, transport:|
  github_token_stub(transport)
  updated = "2026-09-26T12:01:00Z"
  github_paged_stream(transport, "issues", 76.downto(1).map { |id| github_issue(id, updated: updated) }, page_size: 25)
  github_paged_stream(transport, "issue_comments", 201.downto(1).map { |id| github_repo_issue_comment(id, 76, updated: updated) }, page_size: 100)
  github_paged_stream(transport, "review_comments", 401.downto(1).map { |id| github_repo_review_comment(id, 76, updated: updated) }, page_size: 100)
  github_paged_stream(transport, "workflow_runs", 501.downto(1).map { |id| github_run(id, updated: updated) }, page_size: 100)

  first = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r" })
  expect(first["events"].group_by { |event| event["event_type"] }.transform_values(&:size)).to eq({
    "github.issue" => 50, "github.issue_comment" => 200, "github.review_comment" => 200, "github.workflow_run" => 300
  })
  expect(first["cursor"]["streams"].transform_values { |state| URI.decode_www_form(URI.parse(state["next"]).query).to_h["page"] })
    .to eq({ "issues" => "3", "issue_comments" => "3", "review_comments" => "3", "workflow_runs" => "4" })

  transport.requests.clear
  second = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => first["cursor"] })
  GH_STREAM_URLS.each do |name, url|
    expect(transport.requests_to(url).size).to eq(1)
    next_page = { "issues" => 4, "issue_comments" => nil, "review_comments" => 4, "workflow_runs" => 6 }.fetch(name)
    expect(second["cursor"]["streams"][name]["next"]).to eq(next_page && "#{url}&page=#{next_page}")
  end
  expect(second["cursor"]["streams"]["issue_comments"]["completed_at"]).to eq("2026-09-26T12:00:00Z")
  expect(second["cursor"]["streams"]["workflow_runs"]["completed_at"]).to eq(nil)
end

test("github checks new head changes and discovers old reruns without advancing the initial floor") do |registry:, transport:|
  github_token_stub(transport)
  %w[issues issue_comments review_comments].each do |name|
    github_paged_stream(transport, name, [], page_size: name == "issues" ? 25 : 100, since: "2026-09-26T12:00:00Z")
  end
  runs = 301.downto(1).map { |id| github_run(id, updated: "2026-01-01T00:00:00Z") }
  runs.first["updated_at"] = "2026-09-26T12:20:00Z"
  github_paged_stream(transport, "workflow_runs", runs, page_size: 100)
  first = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => { "since" => "2026-09-26T12:00:00Z" } })
  expect(first["events"].map { |event| event["event_id"] }).to eq(["github:workflow_run:301"])
  expect(first["cursor"]["since"]).to eq("2026-09-26T12:00:00Z")

  # A rerun remains on its old creation-date page; it is older than the
  # newest event already emitted. A moving shared watermark would lose it.
  runs.last["updated_at"] = "2026-09-26T12:01:00Z"
  runs.last["run_attempt"] = 2
  runs.first["run_attempt"] = 2
  second = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => first["cursor"] })
  expect(second["events"].map { |event| event["event_id"] }).to eq(["github:workflow_run:1", "github:workflow_run:301"])
  expect(second["events"].last["fingerprint"]).not_to eq(first["events"].first["fingerprint"])
  expect(second["cursor"]["since"]).to eq("2026-09-26T12:00:00Z")
end

test("github restarts complete sweeps so offset deletion does not permanently exclude unread issues") do |registry:, transport:|
  github_token_stub(transport)
  issues = 60.downto(1).map { |id| github_issue(id, updated: "2026-09-26T12:01:00Z") }
  issues.first["updated_at"] = "2026-09-26T13:00:00Z"
  github_paged_stream(transport, "issues", issues, page_size: 25)
  github_empty_lists(transport)
  first = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => { "since" => "2026-09-26T12:00:00Z" } })
  expect(first["cursor"]["streams"]["issues"]["next"]).to eq("#{GH_STREAM_URLS['issues']}&page=3")

  issues.shift(25) # Unread issues moved before the old offset.
  second = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => first["cursor"] })
  expect(second["cursor"]["streams"]["issues"]["next"]).to eq(nil)
  expect(second["events"].any? { |event| event["event_id"] == "github:issue:o/r#1" }).to eq(false)
  third = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => second["cursor"] })
  expect(third["events"].map { |event| event["event_id"] }).to include("github:issue:o/r#1")
  expect([first, second, third].flat_map { |out| out["events"].map { |event| event["event_id"] } }.uniq.size).to eq(60)
  expect(third["cursor"]["since"]).to eq("2026-09-26T12:00:00Z")
end

test("github reconciles edits of old reviews even when the parent has not been updated") do |registry:, transport:|
  github_token_stub(transport)
  github_paged_stream(transport, "issues", [github_issue(1, updated: "2026-01-01T00:00:00Z", pr: true)], page_size: 25)
  github_empty_lists(transport)
  body = "original review"
  transport.stub_proc("GET", %r{/pulls/1/reviews}) do |_request|
    Plugins::Http::Response.new(status: 200, headers: {}, body: JSON.generate([
      { "id" => 100, "state" => "COMMENTED", "body" => body, "submitted_at" => "2026-01-01T01:00:00Z", "user" => { "login" => "reviewer", "type" => "User" } }
    ]))
  end
  first = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => { "since" => "2026-09-26T12:00:00Z" } })
  body = "edited review"
  second = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => first["cursor"] })
  expect(first["events"].map { |event| event["event_id"] }).to eq(["github:review:100"])
  expect(second["events"].first["fingerprint"]).not_to eq(first["events"].first["fingerprint"])
  expect(second["events"].first["occurred_at"]).to eq("2026-01-01T01:00:00Z")
end

test("github failed resumed pages leave the supplied checkpoint unchanged") do |registry:, transport:|
  github_token_stub(transport)
  first = GH_STREAM_URLS["issues"]
  cursor = github_cursor(next_urls: { "issues" => "#{first}&page=3" })
  original = JSON.parse(JSON.generate(cursor))
  transport.stub_json("GET", first, body: [github_issue(99, updated: "2026-09-26T12:00:00Z")], headers: { "Link" => %(<#{first}&page=2>; rel="next") })
  transport.stub_json("GET", "#{first}&page=3", status: 500, body: {})
  expect do
    registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => cursor })
  end.to raise_error(Plugins::HttpError)
  expect(cursor).to eq(original)
  expect(transport.requests_to("#{first}&page=2").size).to eq(0)
end

test("github still fails explicitly for a single PR whose reviews exceed the bounded expansion") do |registry:, transport:|
  github_token_stub(transport)
  github_paged_stream(transport, "issues", [github_issue(1, updated: "2026-09-26T12:00:00Z", pr: true)], page_size: 25)
  github_empty_lists(transport)
  first = "#{GH}/repos/o/r/pulls/1/reviews?per_page=100"
  transport.stub_proc("GET", %r{/pulls/1/reviews}) do |request|
    page = URI.decode_www_form(URI.parse(request[:url]).query).to_h.fetch("page", "1").to_i
    Plugins::Http::Response.new(status: 200, headers: { "Link" => %(<#{first}&page=#{page + 1}>; rel="next") }, body: "[]")
  end
  cursor = github_cursor
  expect do
    registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => cursor })
  end.to raise_error(Plugins::IncompletePoll, /resumable review paging/)
  expect(transport.requests_to(%r{/pulls/1/reviews}).size).to eq(25)
  expect(cursor).to eq(github_cursor)
end

test("github parent fingerprint ignores own reply metadata but preserves body and state changes") do |registry:, transport:|
  github_token_stub(transport)
  issue = github_issue(1, updated: "2026-09-26T12:00:00Z")
  comments = []
  github_paged_stream(transport, "issues", [issue], page_size: 25)
  github_paged_stream(transport, "issue_comments", comments, page_size: 100)
  github_paged_stream(transport, "review_comments", [], page_size: 100)
  github_paged_stream(transport, "workflow_runs", [], page_size: 100)
  poll = -> { registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r" })["events"] }
  original = poll.call.first
  issue["updated_at"] = "2026-09-26T12:01:00Z"
  issue["comments"] = 1
  own_reply = github_repo_issue_comment(100, 1, updated: "2026-09-26T12:01:00Z")
  own_reply["user"] = { "login" => "our-app[bot]", "type" => "Bot" }
  comments << own_reply
  after_reply = poll.call
  parent = after_reply.find { |event| event["event_id"] == original["event_id"] }
  expect(parent["fingerprint"]).to eq(original["fingerprint"])
  expect(parent["actor_id"]).to eq("octo")
  expect(after_reply.find { |event| event["event_id"] == "github:issue_comment:100" }["actor_type"]).to eq("bot")
  issue["body"] = "edited body"
  edited = poll.call.find { |event| event["event_id"] == original["event_id"] }
  expect(edited["fingerprint"]).not_to eq(parent["fingerprint"])
  issue["state"] = "closed"
  closed = poll.call.find { |event| event["event_id"] == original["event_id"] }
  expect(closed["fingerprint"]).not_to eq(edited["fingerprint"])
end

test("github refuses cross-host next links and cursor URLs") do |registry:, transport:|
  github_token_stub(transport)
  page1 = GH_STREAM_URLS["issues"]
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
                             "cursor" => github_cursor(next_urls: { "issues" => "https://evil.test/resume" }) },
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

test("github version two cursors bind stream URLs to repository and query before credentials are sent") do |registry:, transport:|
  first = GH_STREAM_URLS["issues"]
  valid_next = "#{first}&page=2"
  invalid_urls = [
    valid_next.sub("/o/r/", "/other/repository/"),
    valid_next.sub("/repos/o/r/", "/repositories/123/"),
    valid_next.sub("/issues?", "/pulls?"),
    valid_next.sub("per_page=25", "per_page=100"),
    valid_next.sub("direction=desc", "direction=asc"),
    "#{valid_next}&since=2026-09-26T12%3A00%3A00Z",
    "#{valid_next}&page=3", "#{valid_next}#fragment",
    "#{first}&page=1", "#{first}&page=0", "#{first}&page=2.5"
  ]
  invalid_urls.each do |url|
    expect do
      registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => github_cursor(next_urls: { "issues" => url }) })
    end.to raise_error(Plugins::InputInvalid, /repository, stream, filters/)
  end
  unsafe_origins = [valid_next.sub("https:", "http:"), valid_next.sub(GH, "#{GH}:8443"), valid_next.sub("https://", "https://user:password@")]
  unsafe_origins.each do |url|
    expect do
      registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => github_cursor(next_urls: { "issues" => url }) })
    end.to raise_error(Plugins::HostRejected)
  end
  invalid_cursors = [
    github_cursor.merge("version" => 3), github_cursor.merge("scope" => "other/repo"),
    github_cursor.merge("streams" => {}), github_cursor.merge("extra" => true),
    github_cursor(since: "2026-02-30T12:00:00Z"), github_cursor(since: "2026-09-26T12:00:00"),
    github_cursor(completed_at: "2026-02-30T12:00:00Z")
  ]
  malformed_state = github_cursor
  malformed_state["streams"]["issues"].delete("completed_at")
  invalid_cursors << malformed_state
  invalid_cursors.each do |cursor|
    expect do
      registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => cursor })
    end.to raise_error(Plugins::InputInvalid, /cursor/)
  end
  expect(transport.requests).to eq([])
end

test("github uses numeric repository links only as page hints and keeps requests and checkpoints scoped") do |registry:, transport:|
  github_token_stub(transport)
  first = GH_STREAM_URLS["issues"]
  numeric = first.sub("/repos/o/r/", "/repositories/123/")
  transport.stub_json("GET", first, body: [github_issue(1, updated: "2026-09-26T12:00:00Z")],
                      headers: { "Link" => %(<#{numeric}&page=2>; rel="next") })
  transport.stub_json("GET", "#{first}&page=2", body: [github_issue(2, updated: "2026-09-26T12:00:00Z")],
                      headers: { "Link" => %(<#{numeric}&page=3>; rel="next") })
  transport.stub_json("GET", "#{first}&page=3", body: [github_issue(3, updated: "2026-09-26T12:00:00Z")])
  github_empty_lists(transport)
  one = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r" })
  expect(one["events"].map { |event| event["event_id"] }).to eq(["github:issue:o/r#1", "github:issue:o/r#2"])
  expect(one["cursor"]["streams"]["issues"]["next"]).to eq("#{first}&page=3")
  two = registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r", "cursor" => one["cursor"] })
  expect(two["events"].map { |event| event["event_id"] }).to eq(["github:issue:o/r#1", "github:issue:o/r#3"])
  expect(transport.requests_to(%r{/repositories/}).size).to eq(0)
end

test("github rejects same origin links that change repository endpoint filters or page order") do |registry:, transport:|
  github_token_stub(transport)
  first = GH_STREAM_URLS["issues"]
  links = ["#{first.sub('/o/r/', '/other/repo/')}&page=2", "#{GH_STREAM_URLS['issue_comments']}&page=2", "#{first.sub('per_page=25', 'per_page=100')}&page=2", "#{first}&page=3"]
  transport.stub_proc("GET", first) do |_request|
    Plugins::Http::Response.new(status: 200, headers: { "Link" => %(<#{links.shift}>; rel="next") }, body: "[]")
  end
  4.times do
    expect do
      registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r" })
    end.to raise_error(Plugins::OutputInvalid)
  end
  expect(transport.requests.select { |request| request[:method] == "GET" }.map { |request| request[:url] }.uniq).to eq([first])
end

test("github rejects a response that exceeds the requested page size instead of truncating") do |registry:, transport:|
  github_token_stub(transport)
  transport.stub_json("GET", GH_STREAM_URLS["issues"], body: (1..26).map { |id| github_issue(id, updated: "2026-09-26T12:00:00Z") })
  expect do
    registry.invoke(plugin: "github", operation: "latest_events", input: { "scope" => "o/r" })
  end.to raise_error(Plugins::OutputInvalid, /page shape or size/)
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
