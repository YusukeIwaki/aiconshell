# frozen_string_literal: true

require_relative "plugins_test_helper"

test("builtin write preflight rejects impossible targets without credentials or transport") do |registry:, transport:|
  [
    ["github", "reply", { "resource_id" => "o/r", "body" => "hello" }],
    ["github", "create_issue", { "scope" => "invalid", "title" => "hello", "body" => "world" }],
    ["discord", "reply", { "resource_id" => "message:1", "body" => "hello" }],
    ["discord", "send_message", { "scope" => "channel:abc", "body" => "hello" }]
  ].each do |plugin, operation, input|
    expect { registry.validate_input(plugin: plugin, operation: operation, input: input) }
      .to raise_error(Aiconshell::Plugins::InputInvalid)
  end
  expect(transport.requests).to eq([])
end

test("Discord write preflight validates syntax without transport") do |registry:, transport:|
  [
    ["send_message", { "scope" => "channel:130000000000000001", "body" => "hello" }],
    ["reply", { "resource_id" => "message:130000000000000001/130000000000000002", "body" => "hello" }]
  ].each do |operation, input|
    expect(registry.validate_input(plugin: "discord", operation: operation, input: input)).to eq(input)
  end
  expect(transport.requests).to eq([])
end
