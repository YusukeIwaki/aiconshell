# frozen_string_literal: true

require "test_helper"
require_relative "../support/scripted_ai"

SCHEMA_12 = {
  "type" => "object",
  "properties" => { "answer" => { "type" => "string" } },
  "required" => ["answer"]
}.freeze

test("hash script passes through real Runner parsing and schema") do
  BoundaryFixtures.with_ai(answers: [{ "answer" => "hello" }]) do |ctx|
    answer = ctx.runner.call(
      provider: "claude", prompt: "say hi", schema: SCHEMA_12,
      workspace: ctx.workspace, layer: "coordination"
    )
    expect(answer).to eq({ "answer" => "hello" })
    expect(ctx.process_runner.assert_consumed!).to eq(true)
  end
end

test("proc script receives a frozen invocation and answers through real Runner") do
  seen = nil
  script = ->(invocation) { seen = invocation; { "answer" => "from-proc" } }
  BoundaryFixtures.with_ai(answers: [script]) do |ctx|
    answer = ctx.runner.call(
      provider: "claude", prompt: "triage please", schema: SCHEMA_12,
      workspace: ctx.workspace, layer: "coordination"
    )
    expect(answer).to eq({ "answer" => "from-proc" })
    expect(ctx.process_runner.assert_consumed!).to eq(true)
  end
  expect(seen.nil?).to eq(false)
  expect(seen.frozen?).to eq(true)
  expect(seen[:stdin_data]).to eq("triage please")
  expect(seen[:argv].frozen?).to eq(true)
  expect(seen[:env].frozen?).to eq(true)
end

test("invalid structured answer and invalid raw CLI JSON raise real InvalidOutput") do
  BoundaryFixtures.with_ai(answers: [{ "wrong" => 1 }]) do |ctx|
    expect(
      -> {
        ctx.runner.call(
          provider: "claude", prompt: "hi", schema: SCHEMA_12,
          workspace: ctx.workspace, layer: "coordination"
        )
      }
    ).to raise_error(Aiconshell::Ai::InvalidOutput)
    expect(ctx.process_runner.assert_consumed!).to eq(true)
  end

  raw = Aiconshell::Ai::Result.new(
    stdout: "not-json", stderr: "", exit_status: 0,
    timed_out: false, stdout_truncated: false, stderr_truncated: false
  )
  BoundaryFixtures.with_ai(answers: [raw]) do |ctx|
    expect(
      -> {
        ctx.runner.call(
          provider: "claude", prompt: "hi", schema: SCHEMA_12,
          workspace: ctx.workspace, layer: "coordination"
        )
      }
    ).to raise_error(Aiconshell::Ai::InvalidOutput)
  end
end

test("explicit timeout, failure and spawn errors follow real Runner paths") do
  timeout_result = Aiconshell::Ai::Result.new(
    stdout: "", stderr: "", exit_status: nil,
    timed_out: true, stdout_truncated: false, stderr_truncated: false
  )
  BoundaryFixtures.with_ai(answers: [timeout_result]) do |ctx|
    expect(
      -> {
        ctx.runner.call(
          provider: "claude", prompt: "hi", schema: SCHEMA_12,
          workspace: ctx.workspace, layer: "coordination"
        )
      }
    ).to raise_error(Aiconshell::Ai::TimeoutError)
  end

  failing = Aiconshell::Ai::Result.new(
    stdout: "", stderr: "boom", exit_status: 3,
    timed_out: false, stdout_truncated: false, stderr_truncated: false
  )
  BoundaryFixtures.with_ai(answers: [failing]) do |ctx|
    rescued = nil
    begin
      ctx.runner.call(
        provider: "claude", prompt: "hi", schema: SCHEMA_12,
        workspace: ctx.workspace, layer: "coordination"
      )
    rescue Aiconshell::Ai::ExecutionFailed => e
      rescued = e
    end
    expect(rescued.nil?).to eq(false)
    expect(rescued.exit_status).to eq(3)
  end

  BoundaryFixtures.with_ai(answers: [Errno::ENOENT.new("claude")]) do |ctx|
    rescued = nil
    begin
      ctx.runner.call(
        provider: "claude", prompt: "hi", schema: SCHEMA_12,
        workspace: ctx.workspace, layer: "coordination"
      )
    rescue Aiconshell::Ai::ExecutionFailed => e
      rescued = e
    end
    expect(rescued.nil?).to eq(false)
    expect(rescued.exit_status).to eq(nil)
  end
end

test("extra calls fail but stay verifiable after the error is rescued") do
  BoundaryFixtures.with_ai(answers: [{ "answer" => "one" }]) do |ctx|
    ctx.runner.call(
      provider: "claude", prompt: "first", schema: SCHEMA_12,
      workspace: ctx.workspace, layer: "coordination"
    )
    rescued = nil
    begin
      ctx.runner.call(
        provider: "claude", prompt: "second", schema: SCHEMA_12,
        workspace: ctx.workspace, layer: "coordination"
      )
    rescue BoundaryFixtures::ExpectationError => e
      rescued = e
    end
    expect(rescued.nil?).to eq(false)
    expect(ctx.process_runner.calls.size).to eq(2)
    expect(ctx.process_runner.unexpected_calls.size).to eq(1)
    expect(-> { ctx.process_runner.assert_consumed! })
      .to raise_error(BoundaryFixtures::ExpectationError)
  end
end

test("leftover scripts fail verification") do
  BoundaryFixtures.with_ai(answers: [{ "answer" => "one" }, { "answer" => "two" }]) do |ctx|
    ctx.runner.call(
      provider: "claude", prompt: "only first", schema: SCHEMA_12,
      workspace: ctx.workspace, layer: "coordination"
    )
    rescued = nil
    begin
      ctx.process_runner.assert_consumed!
    rescue BoundaryFixtures::ExpectationError => e
      rescued = e
    end
    expect(rescued.nil?).to eq(false)
    expect(rescued.message.include?("unconsumed")).to eq(true)
  end
end

test("enqueue records copies of mutable process inputs") do
  runner = BoundaryFixtures::ScriptedProcessRunner.new
  runner.enqueue({ "answer" => "queued" })
  argv = [+"/synthetic/claude"]
  env = { "HOME" => +"/synthetic/home" }
  prompt = +"original prompt"
  runner.call(argv: argv, env: env, cwd: "/synthetic/workspace", stdin_data: prompt,
              timeout: 10, max_output_bytes: 1000)
  argv.first.replace("changed")
  env["HOME"].replace("changed")
  prompt.replace("changed")

  expect(runner.calls.first[:argv]).to eq(["/synthetic/claude"])
  expect(runner.calls.first[:env]).to eq({ "HOME" => "/synthetic/home" })
  expect(runner.calls.first[:stdin_data]).to eq("original prompt")
  expect(runner.assert_consumed!).to eq(true)
end

test("invalid fixture scripts cannot pass verification after application rescue") do
  expect(-> { BoundaryFixtures::ScriptedProcessRunner.new([:invalid]) }).to raise_error(ArgumentError)

  BoundaryFixtures.with_ai(answers: [->(_call) { nil }]) do |ctx|
    begin
      ctx.runner.call(provider: "claude", prompt: "hi", schema: SCHEMA_12,
                      workspace: ctx.workspace, layer: "coordination")
    rescue BoundaryFixtures::ExpectationError
      # Application services rescue StandardError; verification must still fail.
    end
    expect(-> { ctx.process_runner.assert_consumed! }).to raise_error(BoundaryFixtures::ExpectationError)
  end
end

test("recorded calls carry controlled values and are immutable snapshots") do
  canary_key = "AICONSHELL_ISSUE12_CANARY"
  saved_canary = ENV[canary_key]
  ENV[canary_key] = "canary-value"
  begin
    BoundaryFixtures.with_ai(answers: [{ "answer" => "hello" }]) do |ctx|
      ctx.runner.call(
        provider: "claude", prompt: "triage prompt", schema: SCHEMA_12,
        workspace: ctx.workspace, layer: "coordination"
      )
      call = ctx.process_runner.calls.first
      expect(call[:cwd]).to eq(ctx.workspace)
      expect(call[:stdin_data]).to eq("triage prompt")
      expect(call[:timeout]).to eq(30)
      expect(call[:max_output_bytes]).to eq(100_000)
      expect(call[:kill_grace_seconds]).to eq(1)
      expect(call[:argv].first).to eq(ctx.config.claude_executable)
      expect(call[:argv].any? { |part| part.include?("triage prompt") }).to eq(false)
      expect(call[:env]["PATH"]).to eq("/usr/bin:/bin")
      expect(call[:env]["HOME"]).to eq(ctx.config.controlled_home)
      expect(call[:env]["CLAUDE_CONFIG_DIR"]).to eq(ctx.config.claude_home)
      expect(call[:env].key?(canary_key)).to eq(false)
      expect(call[:env].key?("DATABASE_URL")).to eq(false)
      expect(call.frozen?).to eq(true)
      expect(call[:argv].frozen?).to eq(true)
      expect(call[:env].frozen?).to eq(true)
      expect(call[:env]["PATH"].frozen?).to eq(true)
      cleared = ctx.process_runner.calls
      cleared.clear
      expect(ctx.process_runner.calls.size).to eq(1)
      expect(ctx.process_runner.assert_consumed!).to eq(true)
    end
  ensure
    saved_canary.nil? ? ENV.delete(canary_key) : ENV.store(canary_key, saved_canary)
  end
end

test("isolated registry, fake executable, cleanup and no ENV mutation") do
  canary_key = "AICONSHELL_ISSUE12_ENV_CHECK"
  saved_canary = ENV[canary_key]
  ENV[canary_key] = "present"
  before_keys = ENV.keys.sort
  before_has_claude = ENV.key?("CLAUDE_CONFIG_DIR")
  begin
    captured = nil
    BoundaryFixtures.with_ai(answers: [{ "answer" => "ok" }]) do |ctx|
      captured = ctx
      expect(ctx.registry.providers).to eq(%w[claude codex muse])
      expect(ctx.registry.configured?("claude")).to eq(true)
      expect(File.executable?(ctx.config.claude_executable)).to eq(true)
      expect(File.read(ctx.config.claude_executable).include?("exit 127")).to eq(true)
      expect(Dir.exist?(ctx.config.claude_home)).to eq(true)
      expect(Dir.exist?(ctx.config.codex_home)).to eq(true)
      expect(Dir.exist?(ctx.config.auth_dir_for("muse"))).to eq(true)
      expect(ctx.workspace.start_with?(ctx.root)).to eq(true)
      expect(ctx.workspace.start_with?(ctx.config.claude_home + "/")).to eq(false)
      answer = ctx.runner.call(
        provider: "claude", prompt: "hi", schema: SCHEMA_12,
        workspace: ctx.workspace, layer: "coordination"
      )
      expect(answer).to eq({ "answer" => "ok" })
      expect(Dir.exist?(ctx.root)).to eq(true)
    end
    expect(Dir.exist?(captured.root)).to eq(false)
    expect(Dir.exist?(captured.workspace)).to eq(false)

    failed_root = nil
    begin
      BoundaryFixtures.with_ai(answers: []) do |ctx|
        failed_root = ctx.root
        raise "boom"
      end
    rescue RuntimeError
      nil
    end
    expect(failed_root.nil?).to eq(false)
    expect(Dir.exist?(failed_root)).to eq(false)

    expect(ENV.keys.sort).to eq(before_keys)
    expect(ENV[canary_key]).to eq("present")
    expect(ENV.key?("CLAUDE_CONFIG_DIR")).to eq(before_has_claude)
  ensure
    saved_canary.nil? ? ENV.delete(canary_key) : ENV.store(canary_key, saved_canary)
  end
end
