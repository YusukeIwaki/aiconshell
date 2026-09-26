# frozen_string_literal: true

require "fileutils"
require "json"
require "openssl"
require "tmpdir"
require_relative "../../../lib/aiconshell/plugins"
require_relative "../../support/boundary_fixtures"
require_relative "../../support/scripted_ai"

# Reusable scenario context for issue-12 request acceptance tests.
#
# Composes the committed strict boundary fixtures (HTTP transport +
# scripted AI process runner) with a NEW real plugins Registry holding
# fresh real Github and Teams adapters. Final tests script finite
# HTTP/AI answers here, then drive the real request path.
#
# Only the two boundaries are fake: HTTP (no network) and AI process
# spawn (no CLI, no subscription auth). Registry dispatch, adapters,
# token caching, schema validation and the real Ai::Runner stay active.
# This file never requires Rails: final test files load db_helper first.
module RequestAcceptance
  GITHUB_TOKEN_URL = "https://api.github.com/app/installations/789/access_tokens"
  # Issue-list GETs only (never issue comments); final tests assert the
  # semantic query, so per_page is deliberately not part of the match.
  GITHUB_ISSUES_PATTERN = %r{\Ahttps://api\.github\.com/repos/o/r/issues\?}
  TEAMS_TOKEN_URL = "https://login.microsoftonline.com/fixture-tenant/oauth2/v2.0/token"
  TEAMS_ACTIVITY_URL = "https://bot.example.test/v3/conversations/fixture-conversation/activities"
  TEAMS_WRITE_TARGET = "channel:fixture-team/fixture-channel"
  TEAMS_CHANNEL_SCOPE = "team/fixture-team/channel/fixture-channel"

  APP_ENV_KEYS = %w[
    ADMIN_USERNAME ADMIN_PASSWORD ADMIN_API_TOKEN AICONSHELL_ALLOWED_SCOPES
    AICONSHELL_EXECUTION_ROOT AICONSHELL_AI_TIMEOUT_SECONDS
    AICONSHELL_LEASE_SECONDS AICONSHELL_DEMO_MODE AICONSHELL_SELF_ACTOR_IDS
  ].freeze

  # Deterministic clock for the Registry/transport. Adapters read #now
  # for token caching; tests may #advance it across retry windows.
  class Clock
    def initialize(now = Time.utc(2026, 9, 26, 12, 0, 0))
      @now = now
    end

    attr_reader :now
    alias current now

    def advance(seconds)
      @now += seconds
      self
    end
  end

  # Live scenario wiring. Each expect_* scripts exactly one reply; the
  # strict transport fails on anything unexpected. No global call order
  # is enforced and prompts are never inspected here.
  Context = Struct.new(:root, :execution_root, :teams_targets_path,
                       :transport, :plugin_env, :registry, :clock, :ai,
                       keyword_init: true) do
    def runner = ai.runner
    def process_runner = ai.process_runner
    def workspace = ai.workspace
    def github_issue(...) = RequestAcceptance.github_issue(...)

    def expect_github_token(token: "ghs_fixture_installation_token", expires_at: nil)
      expires_at ||= (clock.now + 3600).iso8601
      transport.expect_json("POST", GITHUB_TOKEN_URL, body: { "token" => token, "expires_at" => expires_at })
      self
    end

    # Raw GitHub issue-list page. next_page is an explicit Link
    # rel="next" URL (same repo, e.g. page=2) or nil for the last page.
    def expect_github_issue_page(issues:, next_page: nil)
      headers = next_page ? { "Link" => %(<#{next_page}>; rel="next") } : {}
      transport.expect_json("GET", GITHUB_ISSUES_PATTERN, body: issues, headers: headers)
      self
    end

    def expect_teams_token(token: "fixture-bot-token", expires_in: 3600)
      transport.expect_json("POST", TEAMS_TOKEN_URL, body: { "access_token" => token, "expires_in" => expires_in })
      self
    end

    def expect_teams_post(external_id:, status: 200)
      transport.expect_json("POST", TEAMS_ACTIVITY_URL, status: status, body: { "id" => external_id })
      self
    end

    # Externally visible Teams activity POSTs only, never OAuth token POSTs.
    def teams_posts
      transport.requests_to(TEAMS_ACTIVITY_URL, method: "POST")
    end

    # Every scripted HTTP reply and AI answer consumed exactly once,
    # with no unexpected boundary calls (even rescued ones).
    def assert_consumed!
      transport.assert_consumed!
      process_runner.assert_consumed!
    end
  end

  class << self
    # Raw GitHub REST issue item for expect_github_issue_page.
    def github_issue(number:, title:, body:, labels: [])
      {
        "id" => 1_000_000 + number, "number" => number, "title" => title, "body" => body,
        "labels" => labels.map { |name| { "name" => name } }, "state" => "open",
        "html_url" => "https://github.com/o/r/issues/#{number}",
        "user" => { "login" => "fixture-user", "id" => 4242, "type" => "User" },
        "created_at" => "2026-09-26T11:00:00Z", "updated_at" => "2026-09-26T12:00:00Z"
      }
    end

    # Fresh scenario: scoped synthetic app ENV, temp execution root and
    # private Teams mapping, and a new Registry over with_ai. Tempdirs
    # are removed and touched ENV keys restored even when the block
    # raises. answers scripts the AI process boundary, one entry per call.
    def with_context(answers: [], &block)
      raise ArgumentError, "with_context requires a block" unless block

      saved = APP_ENV_KEYS.to_h { |key| [key, ENV[key]] }
      begin
        Dir.mktmpdir("request-acceptance-") do |root|
          execution_root = apply_app_env!(root)
          targets_path = write_teams_targets!(root)
          plugin_env = build_plugin_env(targets_path)
          BoundaryFixtures.with_ai(answers: answers) do |ai|
            clock = Clock.new
            transport = BoundaryFixtures::HttpTransport.new(clock: clock)
            registry = Aiconshell::Plugins::Registry.new(env: plugin_env, transport: transport, clock: clock)
            registry.register(Aiconshell::Plugins::Github.new)
            registry.register(Aiconshell::Plugins::Teams.new)
            yield Context.new(root: root, execution_root: execution_root,
                              teams_targets_path: targets_path, transport: transport,
                              plugin_env: plugin_env, registry: registry,
                              clock: clock, ai: ai)
          end
        end
      ensure
        saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
      end
    end

    private

    def apply_app_env!(root)
      execution_root = File.join(root, "execution")
      FileUtils.mkdir_p(execution_root)
      ENV["ADMIN_USERNAME"] = "acceptance-admin"
      ENV["ADMIN_PASSWORD"] = "acceptance-password-synthetic"
      ENV["ADMIN_API_TOKEN"] = "acceptance-token-synthetic"
      ENV["AICONSHELL_ALLOWED_SCOPES"] = "github:o/r,teams:#{TEAMS_CHANNEL_SCOPE}"
      ENV["AICONSHELL_EXECUTION_ROOT"] = execution_root
      ENV["AICONSHELL_AI_TIMEOUT_SECONDS"] = "60"
      ENV["AICONSHELL_LEASE_SECONDS"] = "300"
      ENV["AICONSHELL_DEMO_MODE"] = "0"
      ENV.delete("AICONSHELL_SELF_ACTOR_IDS")
      execution_root
    end

    def write_teams_targets!(root)
      path = File.join(root, "teams-bot-targets.json")
      mapping = { TEAMS_WRITE_TARGET => { "conversation_id" => "fixture-conversation" } }
      File.write(path, JSON.generate(mapping))
      File.chmod(0o600, path)
      path
    end

    def build_plugin_env(targets_path)
      {
        "GITHUB_APP_ID" => "123456", "GITHUB_INSTALLATION_ID" => "789",
        # Generated in memory per context; never written to disk.
        "GITHUB_PRIVATE_KEY" => OpenSSL::PKey::RSA.new(2048).to_pem,
        "TEAMS_TENANT_ID" => "fixture-tenant", "TEAMS_CLIENT_ID" => "fixture-client-id",
        "TEAMS_CLIENT_SECRET" => "fixture-client-secret-synthetic",
        "TEAMS_BOT_APP_ID" => "fixture-bot-app-id", "TEAMS_BOT_APP_PASSWORD" => "fixture-bot-password-synthetic",
        "TEAMS_SERVICE_URL" => "https://bot.example.test", "TEAMS_BOT_TARGETS_FILE" => targets_path
      }
    end
  end
end
