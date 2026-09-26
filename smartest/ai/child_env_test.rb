# frozen_string_literal: true

require_relative "ai_test_helper"

Ai = Aiconshell::Ai unless defined?(Ai)

HOSTILE_ENV = {
  "DATABASE_URL" => "postgres://secret/db",
  "POSTGRES_PASSWORD" => "secret",
  "GITHUB_TOKEN" => "gh_secret",
  "GITHUB_APP_PRIVATE_KEY" => "private-key-bytes",
  "JIRA_API_TOKEN" => "jira-secret",
  "TEAMS_CLIENT_SECRET" => "teams-secret",
  "OPENAI_API_KEY" => "sk-secret",
  "ANTHROPIC_API_KEY" => "sk-ant-secret",
  "META_API_KEY" => "meta-secret",
  "AWS_SECRET_ACCESS_KEY" => "aws-secret",
  "BUNDLE_GEMFILE" => "/app/Gemfile",
  "RAILS_MASTER_KEY" => "master-secret"
}.freeze

test("child env never inherits application or provider secrets") do
  AiTestSupport.with_tmpdir do |root|
    AiTestSupport.with_env(HOSTILE_ENV) do
      config = AiTestSupport.make_config(root, bin: "/nonexistent")
      %w[claude codex muse].each do |provider|
        env = Ai::ChildEnv.build(provider: provider, config: config)
        HOSTILE_ENV.each_key do |key|
          expect(env.key?(key)).to eq(false)
        end
        leaked = env.values.any? { |value| value.to_s.include?("secret") }
        expect(leaked).to eq(false)
      end
    end
  end
end

test("child env exposes only the calling provider credential home") do
  AiTestSupport.with_tmpdir do |root|
    config = AiTestSupport.make_config(root, bin: "/nonexistent")
    claude_env = Ai::ChildEnv.build(provider: "claude", config: config)
    expect(claude_env["CLAUDE_CONFIG_DIR"]).to eq(File.join(root, "homes", "claude"))
    expect(claude_env.key?("CODEX_HOME")).to eq(false)
    expect(claude_env.key?("MUSE_CONFIG_DIR")).to eq(false)

    codex_env = Ai::ChildEnv.build(provider: "codex", config: config)
    expect(codex_env["CODEX_HOME"]).to eq(File.join(root, "homes", "codex"))
    expect(codex_env.key?("CLAUDE_CONFIG_DIR")).to eq(false)

    muse_env = Ai::ChildEnv.build(provider: "muse", config: config)
    expect(muse_env["MUSE_CONFIG_DIR"]).to eq(File.join(root, "homes", "muse"))
    expect(muse_env.key?("CODEX_HOME")).to eq(false)
  end
end

test("child env pins PATH, HOME and locale to controlled values") do
  AiTestSupport.with_tmpdir do |root|
    AiTestSupport.with_env("PATH" => "/evil:/usr/bin", "HOME" => "/home/user") do
      config = AiTestSupport.make_config(root, bin: "/nonexistent")
      env = Ai::ChildEnv.build(provider: "codex", config: config)
      expect(env["PATH"]).to eq("/usr/bin:/bin")
      expect(env["HOME"]).to eq(File.join(root, "controlled-home"))
      expect(env["LANG"]).to eq("C.UTF-8")
      expect(env["LC_ALL"]).to eq("C.UTF-8")
    end
  end
end

test("child env rejects unknown providers") do
  expect { Ai::ChildEnv.build(provider: "gpt", config: Ai::Config.new) }.to raise_error(Ai::UnknownProvider)
end
