# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "timeout"

# OAuth load-order wiring (issue #26, review note on the plugin entry).
# Adapter files used to require only some oauth/* partial files first, while
# Rails services/model/controller files skipped the full entry behind a
# defined? guard on one constant. Either order could leave State, Pkce,
# TokenSet, SecretBox, or PROVIDERS undefined until some unrelated helper
# happened to load the full entry. Every file now requires the full root,
# so any single entry point exposes the whole public surface. These checks
# run in fresh Ruby processes (no Rails boot, no test-helper preload) so a
# lucky require order in this process cannot hide the gap.
module OauthLoadOrderHelper
  EXPECTED = %w[
    Aiconshell::Oauth::State
    Aiconshell::Oauth::Pkce
    Aiconshell::Oauth::TokenSet
    Aiconshell::Oauth::SecretBox
    Aiconshell::Oauth::Config
    Aiconshell::Oauth::Binding
    Aiconshell::Oauth::Error
    Aiconshell::Oauth::ErrorCodes
    Aiconshell::Oauth::Atlassian
    Aiconshell::Oauth::Microsoft
    Aiconshell::Oauth::PROVIDERS
  ].freeze

  module_function

  def lib_dir
    File.expand_path("../../../lib", __dir__)
  end

  def check_entry(entry)
    check_sequence(entry)
  end

  # Requires each entry in order in one fresh process, then checks the
  # full surface. The partial-first sequence reproduces the reported
  # gap: one pre-defined constant must never imply the whole entry.
  def check_sequence(*entries)
    stdout, status = Timeout.timeout(60) do
      Open3.capture2({}, RbConfig.ruby, "-I", lib_dir, "-e", SEQUENCE_SCRIPT, *entries, "--", *EXPECTED)
    end
    [stdout.strip, status.exitstatus]
  end

  SEQUENCE_SCRIPT = <<~'RUBY'.freeze
    separator = ARGV.index("--")
    entries = ARGV[0...separator]
    names = ARGV[(separator + 1)..]
    entries.each { |entry| require entry }
    missing = names.reject do |name|
      begin
        eval(name, TOPLEVEL_BINDING, __FILE__, __LINE__) # standard dynamic constant check
        true
      rescue NameError
        false
      end
    end
    if missing.empty?
      puts "OAUTH_WIRING_OK"
    else
      warn "missing oauth constants: #{missing.join(", ")}"
      exit 1
    end
  RUBY
end

test("requiring only the jira_oauth adapter file exposes the full oauth entry") do
  stdout, code = OauthLoadOrderHelper.check_entry("aiconshell/plugins/jira_oauth")
  expect(code).to eq(0)
  expect(stdout).to eq("OAUTH_WIRING_OK")
end

test("requiring only the teams_oauth adapter file exposes the full oauth entry") do
  stdout, code = OauthLoadOrderHelper.check_entry("aiconshell/plugins/teams_oauth")
  expect(code).to eq(0)
  expect(stdout).to eq("OAUTH_WIRING_OK")
end

test("rails credential provider file loads standalone with the full oauth entry") do
  service = File.expand_path("../../../app/services/oauth/credential_provider.rb", __dir__)
  stdout, code = OauthLoadOrderHelper.check_entry(service)
  expect(code).to eq(0)
  expect(stdout).to eq("OAUTH_WIRING_OK")
end

test("a partial binding preload never hides the rest of the entry from rails files") do
  service = File.expand_path("../../../app/services/oauth/credential_provider.rb", __dir__)
  stdout, code = OauthLoadOrderHelper.check_sequence("aiconshell/oauth/binding", service)
  expect(code).to eq(0)
  expect(stdout).to eq("OAUTH_WIRING_OK")
end
