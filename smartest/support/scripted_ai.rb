# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require_relative "../../lib/aiconshell/ai"

# Scripted AI boundary fixture for request-acceptance tests (issue #12).
#
# ScriptedProcessRunner replaces the process boundary only: every call must
# consume one scripted entry, each entry answers exactly one call, and all
# calls are recorded as immutable snapshots. The real Ai::Runner, adapters
# and JSON Schema validation stay active. No network, spawns, ENV mutation,
# global registries, or Smartest assertions: failures raise ExpectationError.
module BoundaryFixtures
  class ExpectationError < StandardError; end unless const_defined?(:ExpectationError, false)

  class ScriptedProcessRunner
    def initialize(answers = [])
      @scripts = []
      @calls = []
      @unexpected = []
      @invalid_results = 0
      answers.each { |script| enqueue(script) }
    end

    # Append one scripted entry (Hash, Ai::Result, StandardError or Proc).
    # Useful when acceptance scripts are added after intake reveals Task ids.
    def enqueue(script)
      unless script.is_a?(Hash) || script.is_a?(Aiconshell::Ai::Result) ||
             script.is_a?(StandardError) || script.is_a?(Proc)
        raise ArgumentError, "AI script must be a Hash, Ai::Result, error or Proc"
      end

      @scripts << script
      self
    end

    # Exact production ProcessRunner keywords. Hash scripts become authentic
    # Claude success envelopes; Result scripts pass through verbatim; Error
    # scripts raise; Proc scripts receive the frozen invocation record.
    def call(argv:, env:, cwd:, stdin_data: nil, timeout:, max_output_bytes:, kill_grace_seconds: 5)
      invocation = {
        argv: snapshot(argv),
        env: snapshot(env),
        cwd: snapshot(cwd),
        stdin_data: snapshot(stdin_data),
        timeout: timeout,
        max_output_bytes: max_output_bytes,
        kill_grace_seconds: kill_grace_seconds
      }.freeze
      @calls << invocation

      if @scripts.empty?
        @unexpected << invocation
        raise ExpectationError, unexpected_message
      end

      dispatch(@scripts.shift, invocation)
    end

    def calls
      @calls.dup
    end

    def unexpected_calls
      @unexpected.dup
    end

    # Fails on unexpected calls (even rescued ones) and unconsumed scripts.
    def assert_consumed!
      return true if @unexpected.empty? && @scripts.empty? && @invalid_results.zero?

      raise ExpectationError, unconsumed_message
    end

    private

    def dispatch(script, invocation)
      case script
      when Proc
        handle_proc_result(script.call(invocation))
      when Hash
        ok_result(script)
      when Aiconshell::Ai::Result
        script
      when StandardError
        raise script
      else
        raise ArgumentError, "unsupported AI script: #{script.class}"
      end
    end

    def handle_proc_result(returned)
      case returned
      when Hash
        ok_result(returned)
      when Aiconshell::Ai::Result
        returned
      when StandardError
        raise returned
      else
        @invalid_results += 1
        raise ExpectationError, "AI proc must return a Hash, Ai::Result or error"
      end
    end

    def ok_result(answer)
      Aiconshell::Ai::Result.new(
        stdout: JSON.generate({ "type" => "result", "subtype" => "success", "structured_output" => answer }),
        stderr: "",
        exit_status: 0,
        timed_out: false,
        stdout_truncated: false,
        stderr_truncated: false
      )
    end

    # Failure messages carry counts only; never argv/env/stdin/scripts.
    def unexpected_message
      "unexpected AI process call ##{@calls.size} " \
        "(no matching script; #{@scripts.size} script(s) pending)"
    end

    def unconsumed_message
      parts = []
      parts << "#{@unexpected.size} unexpected call(s)" unless @unexpected.empty?
      parts << "#{@scripts.size} unconsumed script(s)" unless @scripts.empty?
      parts << "#{@invalid_results} invalid script result(s)" unless @invalid_results.zero?
      "boundary AI expectations not satisfied: #{parts.join(", ")}"
    end

    # Deep dup + freeze: caller mutation cannot rewrite evidence.
    def snapshot(value)
      case value
      when Hash
        value.to_h.each_with_object({}) do |(key, val), duped|
          duped[snapshot(key)] = snapshot(val)
        end.freeze
      when Array
        value.map { |element| snapshot(element) }.freeze
      when String
        value.dup.freeze
      when Symbol, Numeric, true, false, nil
        value
      else
        begin
          value.dup.freeze
        rescue TypeError
          value
        end
      end
    end
  end

  AiContext = Struct.new(:root, :workspace, :config, :registry, :process_runner, :runner, keyword_init: true)

  # Real Config/Registry/Runner with an injected scripted process runner.
  # Nothing is spawned: the synthetic executable fails if accidentally run.
  # No process ENV, host auth/config, PATH lookup or global registry use.
  def self.with_ai(answers: [])
    raise ArgumentError, "with_ai requires a block" unless block_given?

    Dir.mktmpdir("aiconshell-ai-fixture-") do |root|
      bin = File.join(root, "bin")
      FileUtils.mkdir_p(bin)
      claude_bin = File.join(bin, "claude")
      File.write(claude_bin, "#!/bin/sh\nexit 127\n")
      File.chmod(0o755, claude_bin)

      claude_home = File.join(root, "auth", "claude")
      codex_home = File.join(root, "auth", "codex")
      muse_home = File.join(root, "auth", "muse")
      FileUtils.mkdir_p(claude_home)
      FileUtils.mkdir_p(codex_home)
      FileUtils.mkdir_p(File.join(muse_home, "muse"))
      controlled_home = File.join(root, "controlled-home")
      FileUtils.mkdir_p(controlled_home)
      workspace = File.join(root, "workspace")
      FileUtils.mkdir_p(workspace)

      config = Aiconshell::Ai::Config.new(
        claude_executable: claude_bin,
        codex_executable: File.join(bin, "codex-missing"),
        muse_executable: File.join(bin, "muse-missing"),
        claude_home: claude_home,
        codex_home: codex_home,
        muse_home: muse_home,
        controlled_home: controlled_home,
        default_timeout: 30,
        max_output_bytes: 100_000,
        kill_grace_seconds: 1,
        child_path: "/usr/bin:/bin"
      )
      registry = Aiconshell::Ai::Registry.new(config: config)
      process_runner = ScriptedProcessRunner.new(answers)
      runner = Aiconshell::Ai::Runner.new(registry: registry, process_runner: process_runner, config: config)
      yield AiContext.new(
        root: root, workspace: workspace, config: config,
        registry: registry, process_runner: process_runner, runner: runner
      )
    end
  end
end
