# frozen_string_literal: true

require_relative "plugins_test_helper"

Plugins = Aiconshell::Plugins

test("default registry exposes the github/jira/teams capability catalog") do
  catalog = Plugins::Registry.default.catalog
  by_id = catalog.to_h { |entry| [entry["id"], entry] }

  expect(by_id.keys).to eq(%w[github jira teams])
  expect(by_id["github"]["operations"].map { |op| op["name"] })
    .to eq(%w[latest_events list_issues reply create_issue])
  expect(by_id["teams"]["operations"].map { |op| op["name"] })
    .to eq(%w[latest_events reply send_message create_issue])

  unsupported = by_id["teams"]["operations"].find { |op| op["name"] == "create_issue" }
  expect(unsupported["unsupported"]).to eq(true)
  expect(unsupported["reason"]).to match(/no issue tracker/i)

  by_id.each_value do |entry|
    expect(entry["required_env"].empty?).to eq(false)
    entry["operations"].each do |op|
      expect(op["input_schema"]["type"]).to eq("object")
      expect(op["output_schema"]["type"]).to eq("object")
    end
  end
end

test("catalog reports configured flags without exposing values") do |registry:, plugin_env:|
  catalog = registry.catalog
  expect(catalog.map { |entry| entry["configured"] }).to eq([true, true, true])

  plugin_env.delete("GITHUB_PRIVATE_KEY")
  by_id = registry.catalog.to_h { |entry| [entry["id"], entry] }
  expect(by_id["github"]["configured"]).to eq(false)

  serialized = JSON.generate(registry.catalog)
  expect(serialized).not_to include("jira-api-token")
  expect(serialized).not_to include("client-secret")
  expect(serialized).not_to include("bot-password")
end

test("invoke rejects unknown plugin and unknown operation") do |registry:|
  expect do
    registry.invoke(plugin: "slack", operation: "latest_events",
                    input: { "scope" => "x" }, context: {})
  end.to raise_error(Plugins::UnknownPlugin, /slack/)

  expect do
    registry.invoke(plugin: "github", operation: "destroy",
                    input: {}, context: {})
  end.to raise_error(Plugins::UnknownOperation, /destroy/)
end

test("invoke rejects unsupported teams create_issue") do |registry:|
  expect do
    registry.invoke(plugin: "teams", operation: "create_issue",
                    input: { "scope" => "x", "title" => "t", "body" => "b" },
                    context: {})
  end.to raise_error(Plugins::UnsupportedOperation, /github or jira/i)
end

test("invoke enforces scopes only when context carries them") do |registry:, transport:|
  stub_github_token(transport)
  stub_github_empty_poll(transport)

  # Granted scope passes.
  out = registry.invoke(plugin: "github", operation: "latest_events",
                        input: { "scope" => "o/r" },
                        context: { "scopes" => ["github:read"] })
  expect(out["events"]).to eq([])

  # Missing scope is a typed denial.
  expect do
    registry.invoke(plugin: "github", operation: "reply",
                    input: { "resource_id" => "issue:o/r#1", "body" => "hi" },
                    context: { "scopes" => ["github:read"] })
  end.to raise_error(Plugins::PermissionDenied, /github:write/)

  # Absent scopes list means a fully trusted internal caller.
  transport.stub_json("POST", "https://api.github.com/repos/o/r/issues/1/comments",
                      status: 201, body: { "id" => 11, "html_url" => "https://example.test/c/11" })
  out = registry.invoke(plugin: "github", operation: "reply",
                        input: { "resource_id" => "issue:o/r#1", "body" => "hi" },
                        context: {})
  expect(out["external_id"]).to eq("11")
end

test("input is schema-validated before any external I/O") do |registry:, transport:|
  expect do
    registry.invoke(plugin: "github", operation: "latest_events",
                    input: { "scope" => 42 }, context: {})
  end.to raise_error(Plugins::InputInvalid)
  expect(transport.requests).to eq([])

  expect do
    registry.invoke(plugin: "jira", operation: "reply",
                    input: { "resource_id" => "issue:X-1" }, context: {})
  end.to raise_error(Plugins::InputInvalid, /body/)
  expect(transport.requests).to eq([])

  expect do
    registry.invoke(plugin: "teams", operation: "latest_events",
                    input: "not-a-hash", context: {})
  end.to raise_error(Plugins::InputInvalid, /object/)
  expect(transport.requests).to eq([])
end

test("plugin-level shape checks raise InputInvalid without I/O") do |registry:, transport:|
  expect do
    registry.invoke(plugin: "github", operation: "latest_events",
                    input: { "scope" => "no-slash-here" }, context: {})
  end.to raise_error(Plugins::InputInvalid, /owner\/repo/)
  expect(transport.requests).to eq([])

  expect do
    registry.invoke(plugin: "jira", operation: "create_issue",
                    input: { "scope" => "lowercase", "title" => "t", "body" => "b" },
                    context: {})
  end.to raise_error(Plugins::InputInvalid, /project key/)
  expect(transport.requests).to eq([])
end

test("unexpected remote shapes surface as OutputInvalid") do |registry:, transport:|
  stub_github_token(transport)
  transport.stub_json("POST", "https://api.github.com/repos/o/r/issues",
                      status: 201, body: { "unexpected" => true })

  expect do
    registry.invoke(plugin: "github", operation: "create_issue",
                    input: { "scope" => "o/r", "title" => "t", "body" => "b" },
                    context: {})
  end.to raise_error(Plugins::OutputInvalid, /issue number/)
end

test("per-call context overrides registry collaborators") do |transport:, clock:|
  bare = Plugins::Registry.new(env: {}, transport: transport, clock: clock)
  bare.register(Plugins::Github.new)
  stub_github_token(transport)
  stub_github_empty_poll(transport)

  env = { "GITHUB_APP_ID" => "123456", "GITHUB_INSTALLATION_ID" => "789",
          "GITHUB_PRIVATE_KEY" => TestKeys.github_private_key }
  out = bare.invoke(plugin: "github", operation: "latest_events",
                    input: { "scope" => "o/r" }, context: { "env" => env })
  expect(out["cursor"]["since"]).to eq(nil)
  expect(out["cursor"]["version"]).to eq(2)
  expect(out["cursor"]["streams"]["issues"]["completed_at"]).to eq(clock.now.utc.iso8601)
end

def stub_github_token(transport)
  transport.stub_json("POST", "https://api.github.com/app/installations/789/access_tokens",
                      body: { "token" => "ghs_test", "expires_at" => "2026-09-26T13:00:00Z" })
end

def stub_github_empty_poll(transport)
  transport.stub_json("GET", %r{\Ahttps://api\.github\.com/repos/o/r/issues\?}, body: [])
  transport.stub_json("GET", %r{\Ahttps://api\.github\.com/repos/o/r/issues/comments\?}, body: [])
  transport.stub_json("GET", %r{\Ahttps://api\.github\.com/repos/o/r/pulls/comments\?}, body: [])
  transport.stub_json("GET", %r{\Ahttps://api\.github\.com/repos/o/r/actions/runs\?},
                      body: { "workflow_runs" => [] })
end
