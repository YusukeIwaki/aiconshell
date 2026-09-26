# frozen_string_literal: true

require_relative "ai_test_helper"

Ai = Aiconshell::Ai unless defined?(Ai)

def muse_invocation(overrides = {})
  defaults = {
    prompt: "prioritize", schema: AiTestSupport::SCHEMA, model: nil,
    effort: nil, instructions: nil, workspace: "/tmp/ws",
    layer: "coordination", config: Ai::Config.new,
    files: { schema_file: "/tmp/schema.json", prompt_file: "/tmp/prompt.txt" },
    executable: "/bin/muse"
  }
  Ai::MuseAdapter.invocation(**defaults.merge(overrides))
end

test("muse wires schema, prompt file and workspace root") do
  invocation = muse_invocation
  argv = invocation[:argv]
  expect(argv[0..2]).to eq(["/bin/muse", "exec", "--json"])
  expect(argv[argv.index("--output-schema") + 1]).to eq("/tmp/schema.json")
  expect(argv[argv.index("--prompt-file") + 1]).to eq("/tmp/prompt.txt")
  expect(argv[argv.index("--workspace") + 1]).to eq("/tmp/ws")
  expect(invocation[:stdin_data]).to be_nil
end

test("muse defaults to the contributor model and max effort") do
  argv = muse_invocation[:argv]
  expect(argv[argv.index("--model") + 1]).to eq("muse-spark-1.3-contributor")
  expect(argv[argv.index("--reasoning-effort") + 1]).to eq("max")
end

test("muse model and effort defaults are configurable") do
  config = Ai::Config.new(muse_default_model: "custom-model", muse_default_effort: "low")
  argv = muse_invocation(config: config)[:argv]
  expect(argv[argv.index("--model") + 1]).to eq("custom-model")
  expect(argv[argv.index("--reasoning-effort") + 1]).to eq("low")
  argv = muse_invocation(model: "other", effort: "ultra")[:argv]
  expect(argv[argv.index("--model") + 1]).to eq("other")
  expect(argv[argv.index("--reasoning-effort") + 1]).to eq("ultra")
end

test("muse disables writes, shell and web tools outside execution") do
  %w[interaction coordination].each do |layer|
    argv = muse_invocation(layer: layer)[:argv]
    expect(argv).to include("--disable-write")
    expect(argv).to include("--disable-shell")
    expect(argv).to include("--disable-web-tools")
    expect(argv[argv.index("--approval-mode") + 1]).to eq("never")
    expect(argv).to include("--no-foreign-personal-context")
  end
  argv = muse_invocation(layer: "execution")[:argv]
  expect(argv.include?("--disable-write")).to eq(false)
  expect(argv.include?("--disable-shell")).to eq(false)
end

test("muse never waits on prompts and never disables the sandbox") do
  %w[interaction coordination execution].each do |layer|
    argv = muse_invocation(layer: layer)[:argv]
    expect(argv).to include("--user-input-auto-resolve")
    expect(argv[argv.index("--approval-mode") + 1]).to eq("never")
    expect(argv).to include("--no-foreign-personal-context")
    expect(argv.include?("--yolo")).to eq(false)
    expect(argv.include?("--disable-approval")).to eq(false)
    expect(argv.include?("--disable-sandbox")).to eq(false)
    expect(argv.include?("--trust-workspace")).to eq(false)
    expect(argv.include?("--allow-workspace-switch")).to eq(false)
  end
end

test("muse rejects unknown effort levels") do
  expect { muse_invocation(effort: "extreme") }.to raise_error(ArgumentError)
end

test("muse parses the final JSON from the terminal event") do
  parsed = Ai::MuseAdapter.parse_output(
    stdout: AiTestSupport.muse_success_stdout, stderr: "",
    exit_status: 0, files: {}, config: Ai::Config.new
  )
  expect(parsed).to eq(AiTestSupport::ANSWER)
end

test("muse uses the last terminal event in the stream") do
  first = AiTestSupport.muse_terminal_line(text: JSON.generate({ "answer" => "stale" }))
  second = AiTestSupport.muse_terminal_line(text: JSON.generate(AiTestSupport::ANSWER))
  parsed = Ai::MuseAdapter.parse_output(
    stdout: "#{first}\n#{second}\n", stderr: "",
    exit_status: 0, files: {}, config: Ai::Config.new
  )
  expect(parsed).to eq(AiTestSupport::ANSWER)
end

test("muse treats failed terminals as execution failures") do
  stdout = AiTestSupport.muse_terminal_line(text: "", terminal: "failed", reason: "unauthorized: login expired")
  begin
    Ai::MuseAdapter.parse_output(stdout: stdout, stderr: "", exit_status: 0, files: {}, config: Ai::Config.new)
    raise "expected ExecutionFailed"
  rescue Ai::ExecutionFailed => error
    expect(error.kind).to eq(:auth)
    expect(error.message).to eq('AI provider "muse" failed (exit=0, kind=auth)')
    expect(error.respond_to?(:excerpt)).to eq(false)
  end
end

test("muse rejects streams without terminal events or with malformed JSONL") do
  config = Ai::Config.new
  expect do
    Ai::MuseAdapter.parse_output(
      stdout: "{\"payload_type\":\"run.output.delta\"}\n", stderr: "",
      exit_status: 0, files: {}, config: config
    )
  end.to raise_error(Ai::InvalidOutput)
  expect do
    Ai::MuseAdapter.parse_output(
      stdout: "not json\n#{AiTestSupport.muse_terminal_line}\n", stderr: "",
      exit_status: 0, files: {}, config: config
    )
  end.to raise_error(Ai::InvalidOutput)
  expect do
    stdout = AiTestSupport.muse_terminal_line(text: "plain prose, not json")
    Ai::MuseAdapter.parse_output(stdout: stdout, stderr: "", exit_status: 0, files: {}, config: config)
  end.to raise_error(Ai::InvalidOutput)
end

test("muse surfaces non-zero exits as classified execution failures") do
  begin
    Ai::MuseAdapter.parse_output(
      stdout: "", stderr: "--output-schema is not supported with --provider echo",
      exit_status: 2, files: {}, config: Ai::Config.new
    )
    raise "expected ExecutionFailed"
  rescue Ai::ExecutionFailed => error
    expect(error.exit_status).to eq(2)
    expect(error.kind).to eq(:generic)
  end
end
