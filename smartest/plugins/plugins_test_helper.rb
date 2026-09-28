# frozen_string_literal: true

# Standalone helper for the issue-3 plugins contract suite. Deliberately NOT
# named smartest/test_helper.rb: the Rails foundation lane owns the global
# helper and this lane must not conflict with it. Each test file loads this
# via require_relative.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "base64"
require "json"
require "socket"
require "time"

require "smartest/autorun"
require "aiconshell/plugins"
require_relative "support/fake_transport"

include PluginsTestSupport

class PluginsTestFixtures < Smartest::Fixture
  fixture :clock do
    FakeClock.new(Time.utc(2026, 9, 26, 12, 0, 0))
  end

  fixture :transport do |clock:|
    FakeTransport.new(clock: clock)
  end

  # Complete (fake) credentials for both adapters. Tests delete or
  # override entries to simulate missing/misconfigured environments.
  fixture :plugin_env do
    {
      "GITHUB_APP_ID" => "123456",
      "GITHUB_INSTALLATION_ID" => "789",
      "GITHUB_PRIVATE_KEY" => TestKeys.github_private_key,
      "DISCORD_BOT_TOKEN" => "discord-bot-token"
    }
  end

  fixture :registry do |transport:, clock:, plugin_env:|
    registry = Aiconshell::Plugins::Registry.new(
      env: plugin_env, transport: transport, clock: clock
    )
    registry.register(Aiconshell::Plugins::Github.new)
    registry.register(Aiconshell::Plugins::Discord.new)
    registry
  end
end

around_suite do |suite|
  use_fixture PluginsTestFixtures
  suite.run
end
