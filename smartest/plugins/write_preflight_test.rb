# frozen_string_literal: true

require_relative "plugins_test_helper"

test("builtin write preflight rejects impossible targets without credentials or transport") do |registry:, transport:|
  [
    ["github", "reply", { "resource_id" => "o/r", "body" => "hello" }],
    ["github", "create_issue", { "scope" => "invalid", "title" => "hello", "body" => "world" }],
    ["jira", "reply", { "resource_id" => "PROJ", "body" => "hello" }],
    ["jira", "create_issue", { "scope" => "invalid project", "title" => "hello", "body" => "world" }],
    ["teams", "send_message", { "scope" => "team/t/channel/c", "body" => "hello" }],
    ["teams", "send_message", { "scope" => "message:t/c/m", "body" => "hello" }]
  ].each do |plugin, operation, input|
    expect { registry.validate_input(plugin: plugin, operation: operation, input: input) }
      .to raise_error(Aiconshell::Plugins::InputInvalid)
  end
  expect(transport.requests).to eq([])
end

test("Teams write preflight validates syntax without opening a Bot target file") do |registry:, transport:, plugin_env:|
  plugin_env["TEAMS_BOT_TARGETS_FILE"] = "/does/not/exist"
  [
    ["send_message", { "scope" => "channel:t/c", "body" => "hello" }],
    ["reply", { "resource_id" => "message:t/c/m", "body" => "hello" }],
    ["send_message", { "scope" => "conversation:conversation-id", "body" => "hello" }]
  ].each do |operation, input|
    expect(registry.validate_input(plugin: "teams", operation: operation, input: input)).to eq(input)
  end
  expect(transport.requests).to eq([])
end
