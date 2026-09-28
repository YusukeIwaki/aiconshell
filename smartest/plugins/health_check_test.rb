# frozen_string_literal: true

require_relative "plugins_test_helper"

Plugins = Aiconshell::Plugins unless defined?(Plugins)

def health_registry(transport:, clock:, env:)
  registry = Aiconshell::Plugins::Registry.new(env: env, transport: transport, clock: clock)
  registry.register(Aiconshell::Plugins::Github.new)
  registry.register(Aiconshell::Plugins::Discord.new)
  registry
end

def stub_installation(transport, permissions)
  transport.stub_json("GET", "https://api.github.com/app/installations/789",
                      body: { "id" => 789, "permissions" => permissions })
end

test("github health_check passes with all required permissions") do |transport:, clock:, plugin_env:|
  stub_installation(transport, { "issues" => "write", "pull_requests" => "write",
                                 "actions" => "read", "metadata" => "read" })
  registry = health_registry(transport: transport, clock: clock, env: plugin_env)
  out = registry.invoke(plugin: "github", operation: "health_check", input: {},
                        context: { "scopes" => ["github:read"] })
  expect(out).to eq({ "ok" => true, "missing" => [] })
  request = transport.requests_to("https://api.github.com/app/installations/789").first
  expect(request[:headers]["Authorization"]).to match(/\ABearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/)
end

test("github health_check lists ungranted permission levels") do |transport:, clock:, plugin_env:|
  stub_installation(transport, { "issues" => "read", "actions" => "read", "metadata" => "read" })
  registry = health_registry(transport: transport, clock: clock, env: plugin_env)
  out = registry.invoke(plugin: "github", operation: "health_check", input: {},
                        context: { "scopes" => ["github:read"] })
  expect(out).to eq({ "ok" => false, "missing" => ["issues:write", "pull_requests:write"] })
end

test("github health_check fails closed without credentials and without I/O") do |transport:, clock:, plugin_env:|
  registry = health_registry(transport: transport, clock: clock,
                             env: plugin_env.merge("GITHUB_PRIVATE_KEY" => ""))
  expect do
    registry.invoke(plugin: "github", operation: "health_check", input: {},
                    context: { "scopes" => ["github:read"] })
  end.to raise_error(Plugins::CredentialsMissing)
  expect(transport.requests).to eq([])
end

test("github health_check rejects non-numeric installation ids without I/O") do |transport:, clock:, plugin_env:|
  registry = health_registry(transport: transport, clock: clock,
                             env: plugin_env.merge("GITHUB_INSTALLATION_ID" => "789/x"))
  expect do
    registry.invoke(plugin: "github", operation: "health_check", input: {},
                    context: { "scopes" => ["github:read"] })
  end.to raise_error(Plugins::CredentialsMissing, /numeric/)
  expect(transport.requests).to eq([])
end

test("github health_check rejects unparsable keys without I/O") do |transport:, clock:, plugin_env:|
  registry = health_registry(transport: transport, clock: clock,
                             env: plugin_env.merge("GITHUB_PRIVATE_KEY" => "not-a-key"))
  expect do
    registry.invoke(plugin: "github", operation: "health_check", input: {},
                    context: { "scopes" => ["github:read"] })
  end.to raise_error(Plugins::CredentialsMissing, /unparsable/)
  expect(transport.requests).to eq([])
end

test("github health_check surfaces auth failures and unexpected shapes as typed errors") do |transport:, clock:, plugin_env:|
  transport.stub_json("GET", "https://api.github.com/app/installations/789",
                      status: 401, body: { "message" => "Bad credentials" })
  registry = health_registry(transport: transport, clock: clock, env: plugin_env)
  expect do
    registry.invoke(plugin: "github", operation: "health_check", input: {},
                    context: { "scopes" => ["github:read"] })
  end.to raise_error(Plugins::HttpError)

  transport2 = PluginsTestSupport::FakeTransport.new(clock: clock)
  transport2.stub_json("GET", "https://api.github.com/app/installations/789", body: { "id" => 789 })
  registry2 = health_registry(transport: transport2, clock: clock, env: plugin_env)
  expect do
    registry2.invoke(plugin: "github", operation: "health_check", input: {},
                     context: { "scopes" => ["github:read"] })
  end.to raise_error(Plugins::OutputInvalid, /unexpected shape/)
end

test("discord health_check resolves the bot id") do |transport:, clock:, plugin_env:|
  transport.stub_json("GET", "https://discord.com/api/v10/users/@me",
                      body: { "id" => "130000000000000001", "username" => "bot" })
  registry = health_registry(transport: transport, clock: clock, env: plugin_env)
  out = registry.invoke(plugin: "discord", operation: "health_check", input: {},
                        context: { "scopes" => ["discord:read"] })
  expect(out).to eq({ "ok" => true, "bot_id" => "130000000000000001" })
end

test("discord health_check fails closed without a token and without I/O") do |transport:, clock:, plugin_env:|
  registry = health_registry(transport: transport, clock: clock,
                             env: plugin_env.merge("DISCORD_BOT_TOKEN" => ""))
  expect do
    registry.invoke(plugin: "discord", operation: "health_check", input: {},
                    context: { "scopes" => ["discord:read"] })
  end.to raise_error(Plugins::CredentialsMissing)
  expect(transport.requests).to eq([])
end

test("discord health_check surfaces auth failures as typed errors") do |transport:, clock:, plugin_env:|
  transport.stub_json("GET", "https://discord.com/api/v10/users/@me",
                      status: 401, body: { "message" => "401: Unauthorized" })
  registry = health_registry(transport: transport, clock: clock, env: plugin_env)
  expect do
    registry.invoke(plugin: "discord", operation: "health_check", input: {},
                    context: { "scopes" => ["discord:read"] })
  end.to raise_error(Plugins::HttpError)
end
