# frozen_string_literal: true

require_relative "ai_test_helper"

Ai = Aiconshell::Ai unless defined?(Ai)

def codex_invocation(overrides = {})
  defaults = {
    prompt: "triage inbox", schema: AiTestSupport::SCHEMA, model: nil,
    effort: nil, instructions: nil, workspace: "/tmp/ws",
    layer: "coordination", config: Ai::Config.new,
    files: { schema_file: "/tmp/schema.json", output_file: "/tmp/output.txt" },
    executable: "/bin/codex"
  }
  Ai::CodexAdapter.invocation(**defaults.merge(overrides))
end

test("codex delivers the prompt over stdin with a dash argv") do
  invocation = codex_invocation
  argv = invocation[:argv]
  expect(argv[0..2]).to eq(["/bin/codex", "exec", "--json"])
  expect(argv.last).to eq("-")
  expect(invocation[:stdin_data]).to eq("triage inbox")
  expect(argv.any? { |element| element.include?("triage") }).to eq(false)
end

test("codex folds policy instructions into the stdin document") do
  invocation = codex_invocation(prompt: "do it", instructions: "be terse")
  expect(invocation[:stdin_data]).to eq("Instructions:\nbe terse\n\nTask:\ndo it")
end

test("codex wires schema and result files plus workspace root") do
  argv = codex_invocation[:argv]
  expect(argv[argv.index("--output-schema") + 1]).to eq("/tmp/schema.json")
  expect(argv[argv.index("--output-last-message") + 1]).to eq("/tmp/output.txt")
  expect(argv[argv.index("-C") + 1]).to eq("/tmp/ws")
  expect(argv).to include("--skip-git-repo-check")
end

test("codex sandboxes non-execution layers read-only") do
  %w[interaction coordination].each do |layer|
    argv = codex_invocation(layer: layer)[:argv]
    expect(argv[argv.index("--sandbox") + 1]).to eq("read-only")
  end
  argv = codex_invocation(layer: "execution")[:argv]
  expect(argv[argv.index("--sandbox") + 1]).to eq("workspace-write")
end

test("codex maps model and effort from policy") do
  argv = codex_invocation(model: "gpt-5", effort: "high")[:argv]
  expect(argv[argv.index("-m") + 1]).to eq("gpt-5")
  expect(argv[argv.index("-c") + 1]).to eq("model_reasoning_effort=\"high\"")
end

test("codex rejects unknown effort instead of emitting unsafe TOML") do
  expect { codex_invocation(effort: "max\"; evil=\"") }.to raise_error(ArgumentError)
end

test("codex parses the last-message file as the answer") do
  AiTestSupport.with_tmpdir do |root|
    output = File.join(root, "output.txt")
    File.write(output, JSON.generate(AiTestSupport::ANSWER))
    parsed = Ai::CodexAdapter.parse_output(
      stdout: "", stderr: "", exit_status: 0,
      files: { output_file: output }, config: Ai::Config.new
    )
    expect(parsed).to eq(AiTestSupport::ANSWER)
  end
end

test("codex treats missing, empty or invalid message files as invalid output") do
  config = Ai::Config.new
  AiTestSupport.with_tmpdir do |root|
    missing = File.join(root, "missing.txt")
    expect do
      Ai::CodexAdapter.parse_output(stdout: "", stderr: "", exit_status: 0, files: { output_file: missing }, config: config)
    end.to raise_error(Ai::InvalidOutput)

    empty = File.join(root, "empty.txt")
    File.write(empty, "  \n")
    expect do
      Ai::CodexAdapter.parse_output(stdout: "", stderr: "", exit_status: 0, files: { output_file: empty }, config: config)
    end.to raise_error(Ai::InvalidOutput)

    broken = File.join(root, "broken.txt")
    File.write(broken, "{\"answer\":" )
    expect do
      Ai::CodexAdapter.parse_output(stdout: "", stderr: "", exit_status: 0, files: { output_file: broken }, config: config)
    end.to raise_error(Ai::InvalidOutput)
  end
end

test("codex classifies usage-limit and auth failures from stderr") do
  config = Ai::Config.new
  begin
    Ai::CodexAdapter.parse_output(stdout: "", stderr: "429 rate_limit exceeded", exit_status: 1, files: {}, config: config)
    raise "expected ExecutionFailed"
  rescue Ai::ExecutionFailed => error
    expect(error.kind).to eq(:usage_limit)
  end
  begin
    Ai::CodexAdapter.parse_output(stdout: "", stderr: "error: authentication required, run codex login", exit_status: 1, files: {}, config: config)
    raise "expected ExecutionFailed"
  rescue Ai::ExecutionFailed => error
    expect(error.kind).to eq(:auth)
  end
end
