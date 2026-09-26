# frozen_string_literal: true

require_relative "ai_test_helper"

Ai = Aiconshell::Ai unless defined?(Ai)

def claude_invocation(overrides = {})
  defaults = {
    prompt: "summarize", schema: AiTestSupport::SCHEMA, model: nil,
    effort: nil, instructions: nil, workspace: "/tmp/ws",
    layer: "coordination", config: Ai::Config.new,
    files: {}, executable: "/bin/claude"
  }
  Ai::ClaudeAdapter.invocation(**defaults.merge(overrides))
end

test("claude builds a print-mode argv array with inline JSON schema") do
  invocation = claude_invocation
  argv = invocation[:argv]
  expect(argv[0..3]).to eq(["/bin/claude", "-p", "--output-format", "json"])
  index = argv.index("--json-schema")
  expect(JSON.parse(argv[index + 1])).to eq(AiTestSupport::SCHEMA)
  expect(argv.last).to eq("summarize")
  expect(invocation[:stdin_data]).to be_nil
  expect(argv.all?(String)).to eq(true)
end

test("claude keeps hostile prompt text as one argv element without interpolation") do
  prompt = "do $(rm -rf /) `evil` ; --model hacked"
  argv = claude_invocation(prompt: prompt)[:argv]
  expect(argv.last).to eq(prompt)
  expect(argv.count(prompt)).to eq(1)
end

test("claude disables all tools for interaction and coordination layers") do
  %w[interaction coordination].each do |layer|
    argv = claude_invocation(layer: layer)[:argv]
    expect(argv).to include("--tools")
    expect(argv[argv.index("--tools") + 1]).to eq("")
    expect(argv).to include("--permission-mode")
    expect(argv[argv.index("--permission-mode") + 1]).to eq("plan")
    expect(argv).to include("--permission-prompts")
  end
end

test("claude confines the execution layer to workspace file tools") do
  argv = claude_invocation(layer: "execution", workspace: "/tmp/ws")[:argv]
  expect(argv[argv.index("--tools") + 1]).to eq("Read,Edit,Write,Glob,Grep,Bash")
  expect(argv[argv.index("--permission-mode") + 1]).to eq("acceptEdits")
  expect(argv[argv.index("--add-dir") + 1]).to eq("/tmp/ws")
end

test("claude maps model, effort and instructions from policy") do
  argv = claude_invocation(model: "sonnet", effort: "max", instructions: "be brief")[:argv]
  expect(argv[argv.index("--model") + 1]).to eq("sonnet")
  expect(argv[argv.index("--effort") + 1]).to eq("max")
  expect(argv[argv.index("--system-prompt") + 1]).to eq("be brief")
end

test("claude rejects unknown effort levels deterministically") do
  expect { claude_invocation(effort: "ultra") }.to raise_error(ArgumentError)
end

test("claude parses structured_output from a success envelope") do
  parsed = Ai::ClaudeAdapter.parse_output(
    stdout: AiTestSupport.claude_success_stdout, stderr: "",
    exit_status: 0, files: {}, config: Ai::Config.new
  )
  expect(parsed).to eq(AiTestSupport::ANSWER)
end

test("claude treats success without structured_output as invalid") do
  stdout = JSON.generate({ "type" => "result", "subtype" => "success", "result" => "plain text" })
  expect do
    Ai::ClaudeAdapter.parse_output(stdout: stdout, stderr: "", exit_status: 0, files: {}, config: Ai::Config.new)
  end.to raise_error(Ai::InvalidOutput)
end

test("claude maps error subtypes to ExecutionFailed with redacted excerpt") do
  stdout = AiTestSupport.claude_error_stdout(errors: ["rate limit reached, try again later"])
  begin
    Ai::ClaudeAdapter.parse_output(stdout: stdout, stderr: "", exit_status: 0, files: {}, config: Ai::Config.new)
    raise "expected ExecutionFailed"
  rescue Ai::ExecutionFailed => error
    expect(error.kind).to eq(:usage_limit)
    expect(error.exit_status).to eq(0)
  end
end

test("claude classifies auth failures on non-zero exit") do
  begin
    Ai::ClaudeAdapter.parse_output(
      stdout: "", stderr: "Error: Not logged in. Please run claude login",
      exit_status: 1, files: {}, config: Ai::Config.new
    )
    raise "expected ExecutionFailed"
  rescue Ai::ExecutionFailed => error
    expect(error.kind).to eq(:auth)
    expect(error.excerpt.include?("Not logged in")).to eq(true)
  end
end

test("claude rejects truncated and non-JSON stdout") do
  config = Ai::Config.new
  expect do
    Ai::ClaudeAdapter.parse_output(stdout: "{\"type\":\"result\",", stderr: "", exit_status: 0, files: {}, config: config)
  end.to raise_error(Ai::InvalidOutput)
  expect do
    Ai::ClaudeAdapter.parse_output(stdout: "[1,2]", stderr: "", exit_status: 0, files: {}, config: config)
  end.to raise_error(Ai::InvalidOutput)
end
