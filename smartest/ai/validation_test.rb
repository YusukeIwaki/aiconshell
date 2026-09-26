# frozen_string_literal: true

require_relative "ai_test_helper"

Ai = Aiconshell::Ai unless defined?(Ai)

# Unprefixed sentinel: matches no secret pattern, so only full omission
# (never pattern redaction) keeps it out of public errors.
SENTINEL = "zk9q2-sentinal-77x".freeze

test("execution failures never echo stderr") do
  config = Ai::Config.new
  stderr = "boom #{SENTINEL} bearer abc123 api_key=hunter2"
  {
    "claude" => Ai::ClaudeAdapter, "codex" => Ai::CodexAdapter, "muse" => Ai::MuseAdapter
  }.each do |provider, adapter|
    begin
      adapter.parse_output(stdout: "", stderr: stderr, exit_status: 3, files: {}, config: config)
      raise "expected ExecutionFailed for #{provider}"
    rescue Ai::ExecutionFailed => error
      expect(error.message).to eq(%(AI provider "#{provider}" failed (exit=3, kind=generic)))
      expect(error.message.include?(SENTINEL)).to eq(false)
      expect(error.inspect.include?(SENTINEL)).to eq(false)
    end
  end
end

test("terminal-failure envelopes never echo their detail text") do
  config = Ai::Config.new
  claude_stdout = AiTestSupport.claude_error_stdout(errors: ["fell over #{SENTINEL}"])
  begin
    Ai::ClaudeAdapter.parse_output(stdout: claude_stdout, stderr: "", exit_status: 0, files: {}, config: config)
    raise "expected ExecutionFailed"
  rescue Ai::ExecutionFailed => error
    expect(error.message.include?(SENTINEL)).to eq(false)
  end

  muse_stdout = AiTestSupport.muse_terminal_line(text: "", terminal: "failed", reason: "denied #{SENTINEL}")
  begin
    Ai::MuseAdapter.parse_output(stdout: muse_stdout, stderr: "", exit_status: 0, files: {}, config: config)
    raise "expected ExecutionFailed"
  rescue Ai::ExecutionFailed => error
    expect(error.message.include?(SENTINEL)).to eq(false)
  end
end

test("invalid-output errors never echo stdout or parser detail") do
  config = Ai::Config.new
  # Broken JSON embedding the sentinel: parser messages may quote input.
  bad = %({"answer": "#{SENTINEL})
  begin
    Ai::ClaudeAdapter.parse_output(stdout: bad, stderr: "", exit_status: 0, files: {}, config: config)
    raise "expected InvalidOutput for claude"
  rescue Ai::InvalidOutput => error
    expect(error.message.include?(SENTINEL)).to eq(false)
  end

  begin
    Ai::MuseAdapter.parse_output(stdout: "#{bad}\n", stderr: "", exit_status: 0, files: {}, config: config)
    raise "expected InvalidOutput for muse"
  rescue Ai::InvalidOutput => error
    expect(error.message.include?(SENTINEL)).to eq(false)
  end

  AiTestSupport.with_tmpdir do |root|
    output = File.join(root, "output.txt")
    File.write(output, bad)
    begin
      Ai::CodexAdapter.parse_output(stdout: "", stderr: "", exit_status: 0, files: { output_file: output }, config: config)
      raise "expected InvalidOutput for codex"
    rescue Ai::InvalidOutput => error
      expect(error.message.include?(SENTINEL)).to eq(false)
    end
  end
end

test("schema violations never echo offending values") do
  begin
    Ai::SchemaValidator.validate!({ "answer" => 42, "note" => SENTINEL }, AiTestSupport::SCHEMA, provider: "muse")
    raise "expected InvalidOutput"
  rescue Ai::InvalidOutput => error
    expect(error.message.include?(SENTINEL)).to eq(false)
    expect(error.message.include?("42")).to eq(false)
  end
end

test("failure classification distinguishes auth, limits and missing CLIs") do
  expect(Ai::Redactor.failure_kind("Error: Not logged in")).to eq(:auth)
  expect(Ai::Redactor.failure_kind("usage limit reached")).to eq(:usage_limit)
  expect(Ai::Redactor.failure_kind("HTTP 429 too many requests")).to eq(:usage_limit)
  expect(Ai::Redactor.failure_kind("claude: command not found")).to eq(:not_found)
  expect(Ai::Redactor.failure_kind("something else broke")).to eq(:generic)
end

test("schema validator accepts matching output") do
  data = Ai::SchemaValidator.validate!(AiTestSupport::ANSWER.dup, AiTestSupport::SCHEMA, provider: "codex")
  expect(data).to eq(AiTestSupport::ANSWER)
end

test("schema validator reports pointers without echoing values") do
  begin
    Ai::SchemaValidator.validate!({ "answer" => 42 }, AiTestSupport::SCHEMA, provider: "codex")
    raise "expected InvalidOutput"
  rescue Ai::InvalidOutput => error
    expect(error.message.include?("/answer")).to eq(true)
    expect(error.message.include?("42")).to eq(false)
  end
end

test("schema validator refuses remote refs without network access") do
  schema = { "type" => "object", "$ref" => "https://example.com/schema.json" }
  expect do
    Ai::SchemaValidator.validate!({}, schema, provider: "codex")
  end.to raise_error(ArgumentError)
end

test("schema validator rejects non-hash schemas") do
  expect do
    Ai::SchemaValidator.validate!({}, [], provider: "codex")
  end.to raise_error(ArgumentError)
end
