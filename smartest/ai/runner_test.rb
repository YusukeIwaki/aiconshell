# frozen_string_literal: true

require_relative "ai_test_helper"

Ai = Aiconshell::Ai unless defined?(Ai)

def with_ai_setup(bin_names, hostile: false)
  AiTestSupport.with_tmpdir do |root|
    bin = AiTestSupport.make_bin(root, bin_names)
    env = { "PATH" => bin }
    env["DATABASE_URL"] = "postgres://secret/db" if hostile
    env["OPENAI_API_KEY"] = "sk-secret" if hostile
    AiTestSupport.with_env(env) do
      config = AiTestSupport.make_config(root, bin: bin)
      registry = Ai::Registry.new(config: config)
      workspace = AiTestSupport.make_workspace(root)
      yield root, config, registry, workspace
    end
  end
end

test("runner executes claude and returns the validated answer") do
  with_ai_setup(%w[claude]) do |_root, config, registry, workspace|
    fake = FakeProcessRunner.new([FakeProcessRunner.ok(stdout: AiTestSupport.claude_success_stdout)])
    answer = Ai::Runner.new(registry: registry, process_runner: fake, config: config).call(
      provider: "claude", prompt: "say hi", schema: AiTestSupport::SCHEMA,
      workspace: workspace, layer: "coordination"
    )
    expect(answer).to eq(AiTestSupport::ANSWER)
    call = fake.calls.first
    expect(call[:cwd]).to eq(workspace)
    expect(call[:timeout]).to eq(30)
    expect(call[:argv][0].end_with?("/bin/claude")).to eq(true)
    expect(call[:stdin_data]).to eq("say hi")
    expect(call[:argv].any? { |element| element.include?("say hi") }).to eq(false)
  end
end

test("runner executes codex with schema and prompt delivery") do
  with_ai_setup(%w[codex]) do |_root, config, registry, workspace|
    seen = {}
    fake = FakeProcessRunner.new do |call|
      schema_path = call[:argv][call[:argv].index("--output-schema") + 1]
      seen[:schema] = JSON.parse(File.read(schema_path))
      seen[:stdin] = call[:stdin_data]
      AiTestSupport.codex_success_behavior.call(call)
    end
    answer = Ai::Runner.new(registry: registry, process_runner: fake, config: config).call(
      provider: "codex", prompt: "triage", schema: AiTestSupport::SCHEMA,
      workspace: workspace, layer: "execution", model: "gpt-5", effort: "high",
      instructions: "be terse"
    )
    expect(answer).to eq(AiTestSupport::ANSWER)
    expect(seen[:schema]).to eq(AiTestSupport::SCHEMA)
    expect(seen[:stdin]).to eq("Instructions:\nbe terse\n\nTask:\ntriage")
  end
end

test("runner executes muse with prompt file and default model") do
  with_ai_setup(%w[muse]) do |_root, config, registry, workspace|
    seen = {}
    fake = FakeProcessRunner.new do |call|
      prompt_path = call[:argv][call[:argv].index("--prompt-file") + 1]
      seen[:prompt_file] = File.read(prompt_path)
      seen[:argv] = call[:argv]
      FakeProcessRunner.ok(stdout: AiTestSupport.muse_success_stdout)
    end
    answer = Ai::Runner.new(registry: registry, process_runner: fake, config: config).call(
      provider: "muse", prompt: "plan", schema: AiTestSupport::SCHEMA,
      workspace: workspace, layer: "coordination"
    )
    expect(answer).to eq(AiTestSupport::ANSWER)
    expect(seen[:prompt_file]).to eq("plan")
    expect(seen[:argv][seen[:argv].index("--model") + 1]).to eq("muse-spark-1.3-contributor")
  end
end

test("runner passes a filtered child env even with hostile process env") do
  with_ai_setup(%w[codex], hostile: true) do |_root, config, registry, workspace|
    fake = FakeProcessRunner.new(&AiTestSupport.codex_success_behavior)
    Ai::Runner.new(registry: registry, process_runner: fake, config: config).call(
      provider: "codex", prompt: "hi", schema: AiTestSupport::SCHEMA,
      workspace: workspace, layer: "coordination"
    )
    env = fake.calls.first[:env]
    expect(env.key?("DATABASE_URL")).to eq(false)
    expect(env.key?("OPENAI_API_KEY")).to eq(false)
    expect(env["CODEX_HOME"]).to eq(config.codex_home)
    expect(env["PATH"]).to eq("/usr/bin:/bin")
  end
end

test("runner fails unconfigured providers at execution time") do
  with_ai_setup([]) do |_root, config, registry, workspace|
    fake = FakeProcessRunner.new([])
    begin
      Ai::Runner.new(registry: registry, process_runner: fake, config: config).call(
        provider: "muse", prompt: "hi", schema: AiTestSupport::SCHEMA,
        workspace: workspace, layer: "coordination"
      )
      raise "expected NotConfigured"
    rescue Ai::NotConfigured => error
      expect(error.provider).to eq("muse")
      expect(error.diagnosis[:executable_found]).to eq(false)
    end
    expect(fake.calls).to eq([])
  end
end

test("runner maps timeouts and failures without leaking stdout") do
  with_ai_setup(%w[claude]) do |_root, config, registry, workspace|
    timeout_runner = Ai::Runner.new(
      registry: registry, process_runner: FakeProcessRunner.new([FakeProcessRunner.timeout]), config: config
    )
    expect do
      timeout_runner.call(provider: "claude", prompt: "hi", schema: AiTestSupport::SCHEMA, workspace: workspace, layer: "coordination")
    end.to raise_error(Ai::TimeoutError)

    failing = FakeProcessRunner.new([FakeProcessRunner.ok(stdout: "", stderr: "boom " + ("x" * 2000), exit_status: 3)])
    begin
      Ai::Runner.new(registry: registry, process_runner: failing, config: config).call(
        provider: "claude", prompt: "hi", schema: AiTestSupport::SCHEMA, workspace: workspace, layer: "coordination"
      )
      raise "expected ExecutionFailed"
    rescue Ai::ExecutionFailed => error
      expect(error.exit_status).to eq(3)
      expect(error.message).to eq('AI provider "claude" failed (exit=3, kind=generic)')
    end
  end
end

test("runner rejects answers that violate the schema") do
  with_ai_setup(%w[muse]) do |_root, config, registry, workspace|
    bad = AiTestSupport.muse_terminal_line(text: JSON.generate({ "wrong" => 1 }))
    fake = FakeProcessRunner.new([FakeProcessRunner.ok(stdout: bad + "\n")])
    expect do
      Ai::Runner.new(registry: registry, process_runner: fake, config: config).call(
        provider: "muse", prompt: "hi", schema: AiTestSupport::SCHEMA, workspace: workspace, layer: "coordination"
      )
    end.to raise_error(Ai::InvalidOutput)
  end
end

test("runner rejects truncated stdout before parsing") do
  with_ai_setup(%w[muse]) do |_root, config, registry, workspace|
    result = Aiconshell::Ai::Result.new(
      stdout: AiTestSupport.muse_success_stdout, stderr: "", exit_status: 0,
      timed_out: false, stdout_truncated: true, stderr_truncated: false
    )
    fake = FakeProcessRunner.new([result])
    expect do
      Ai::Runner.new(registry: registry, process_runner: fake, config: config).call(
        provider: "muse", prompt: "hi", schema: AiTestSupport::SCHEMA, workspace: workspace, layer: "coordination"
      )
    end.to raise_error(Ai::InvalidOutput)
  end
end

test("runner validates layer, prompt, schema and timeout deterministically") do
  with_ai_setup(%w[claude]) do |_root, config, registry, workspace|
    runner = Ai::Runner.new(registry: registry, process_runner: FakeProcessRunner.new([]), config: config)
    base = { provider: "claude", prompt: "hi", schema: AiTestSupport::SCHEMA, workspace: workspace, layer: "coordination" }
    expect { runner.call(**base.merge(layer: "planning")) }.to raise_error(ArgumentError)
    expect { runner.call(**base.merge(prompt: "  ")) }.to raise_error(ArgumentError)
    expect { runner.call(**base.merge(schema: { "type" => "array" })) }.to raise_error(ArgumentError)
    expect { runner.call(**base.merge(timeout: 0)) }.to raise_error(ArgumentError)
    expect { runner.call(**base.merge(provider: "gpt")) }.to raise_error(Ai::UnknownProvider)
  end
end

test("runner refuses workspaces that overlap auth locations or do not exist") do
  with_ai_setup(%w[codex]) do |root, config, registry, _workspace|
    runner = Ai::Runner.new(registry: registry, process_runner: FakeProcessRunner.new([]), config: config)
    base = { provider: "codex", prompt: "hi", schema: AiTestSupport::SCHEMA, layer: "coordination" }
    expect { runner.call(**base.merge(workspace: "relative/path")) }.to raise_error(ArgumentError)
    expect { runner.call(**base.merge(workspace: File.join(root, "missing"))) }.to raise_error(ArgumentError)
    expect { runner.call(**base.merge(workspace: config.codex_home)) }.to raise_error(ArgumentError)
    nested = File.join(config.codex_home, "nested")
    FileUtils.mkdir_p(nested)
    expect { runner.call(**base.merge(workspace: nested)) }.to raise_error(ArgumentError)
    link = File.join(root, "evil-ws")
    File.symlink(config.codex_home, link)
    expect { runner.call(**base.merge(workspace: link)) }.to raise_error(ArgumentError)
    parent_link = File.join(root, "evil-parent")
    File.symlink(File.join(root, "homes"), parent_link)
    expect { runner.call(**base.merge(workspace: parent_link)) }.to raise_error(ArgumentError)
  end
end

test("runner translates spawn errors into classified execution failures") do
  with_ai_setup(%w[claude]) do |_root, config, registry, workspace|
    exploding = FakeProcessRunner.new do |_call|
      raise Errno::ENOENT, "claude"
    end
    begin
      Ai::Runner.new(registry: registry, process_runner: exploding, config: config).call(
        provider: "claude", prompt: "hi", schema: AiTestSupport::SCHEMA, workspace: workspace, layer: "coordination"
      )
      raise "expected ExecutionFailed"
    rescue Ai::ExecutionFailed => error
      expect(error.kind).to eq(:not_found)
      expect(error.exit_status).to be_nil
    end
  end
end
