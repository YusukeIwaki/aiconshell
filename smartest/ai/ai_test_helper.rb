# frozen_string_literal: true

# Standalone helper for the Ai lane. Intentionally NOT smartest/test_helper.rb:
# the Rails foundation lane owns the global helper. Ai tests require this file
# directly and stay runnable without Rails, gems beyond json_schemer/smartest,
# live accounts, AI calls or network services.
require "smartest/autorun"

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "aiconshell/ai"

require "fileutils"
require "json"
require "tmpdir"

# Scriptable stand-in for Aiconshell::Ai::ProcessRunner. Records every call
# and answers from a queue or a behavior lambda. Behaviors may write the
# CLI output files (codex --output-last-message) to simulate a real run.
class FakeProcessRunner
  attr_reader :calls

  def initialize(results = [], &behavior)
    @results = results.dup
    @behavior = behavior
    @calls = []
  end

  def call(argv:, env:, cwd:, stdin_data:, timeout:, max_output_bytes:, kill_grace_seconds:)
    call = {
      argv: argv, env: env, cwd: cwd, stdin_data: stdin_data,
      timeout: timeout, max_output_bytes: max_output_bytes,
      kill_grace_seconds: kill_grace_seconds
    }
    @calls << call
    return @behavior.call(call) if @behavior

    raise "FakeProcessRunner: no scripted result left" if @results.empty?

    @results.shift
  end

  def self.ok(stdout: "", stderr: "", exit_status: 0)
    Aiconshell::Ai::Result.new(
      stdout: stdout, stderr: stderr, exit_status: exit_status,
      timed_out: false, stdout_truncated: false, stderr_truncated: false
    )
  end

  def self.timeout
    Aiconshell::Ai::Result.new(
      stdout: "", stderr: "", exit_status: nil,
      timed_out: true, stdout_truncated: false, stderr_truncated: false
    )
  end
end

# Plain module functions so tests need no Smartest context magic.
module AiTestSupport
  SCHEMA = {
    "type" => "object",
    "properties" => { "answer" => { "type" => "string" } },
    "required" => ["answer"]
  }.freeze

  ANSWER = { "answer" => "hello" }.freeze

  module_function

  def with_tmpdir
    Dir.mktmpdir("aiconshell-ai-test-") { |dir| yield dir }
  end

  def with_env(vars)
    saved = {}
    vars.each_key { |key| saved[key] = ENV[key] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
  end

  # Fake executable stubs; returns bin dir. Names absent from the list are
  # "not installed".
  def make_bin(root, names)
    bin = File.join(root, "bin")
    FileUtils.mkdir_p(bin)
    names.each do |name|
      path = File.join(bin, name)
      File.write(path, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, path)
    end
    bin
  end

  def make_config(root, bin:, homes: %w[claude codex muse], **overrides)
    homes.each { |name| FileUtils.mkdir_p(File.join(root, "homes", name)) }
    defaults = {
      claude_home: File.join(root, "homes", "claude"),
      codex_home: File.join(root, "homes", "codex"),
      muse_home: File.join(root, "homes", "muse"),
      controlled_home: File.join(root, "controlled-home"),
      default_timeout: 30,
      max_output_bytes: 100_000,
      child_path: "/usr/bin:/bin"
    }
    Aiconshell::Ai::Config.new(**defaults.merge(overrides))
  end

  def make_workspace(root)
    workspace = File.join(root, "workspace")
    FileUtils.mkdir_p(workspace)
    workspace
  end

  def claude_success_stdout(answer = ANSWER)
    JSON.generate({ "type" => "result", "subtype" => "success", "structured_output" => answer })
  end

  def claude_error_stdout(subtype: "error_during_execution", errors: ["boom"])
    JSON.generate({ "type" => "result", "subtype" => subtype, "errors" => errors })
  end

  def muse_terminal_line(text: JSON.generate(ANSWER), terminal: "completed", reason: nil)
    JSON.generate({
      "payload_type" => "run.terminal.#{terminal}",
      "payload" => { "kind" => "run_terminal", "terminal" => terminal, "text" => text, "reason" => reason }
    })
  end

  def muse_success_stdout(answer = ANSWER)
    noise = JSON.generate({ "payload_type" => "run.output.delta", "payload" => { "kind" => "delta" } })
    "#{noise}\n#{muse_terminal_line(text: JSON.generate(answer))}\n"
  end

  # Behavior simulating a successful codex run: writes the last-message file
  # referenced by argv, mirroring `codex exec --output-last-message`.
  def codex_success_behavior(answer = ANSWER)
    lambda do |call|
      index = call[:argv].index("--output-last-message")
      raise "missing --output-last-message in #{call[:argv].inspect}" if index.nil?

      File.write(call[:argv][index + 1], JSON.generate(answer))
      FakeProcessRunner.ok(stdout: "{\"payload_type\":\"codex.noise\"}\n")
    end
  end
end
