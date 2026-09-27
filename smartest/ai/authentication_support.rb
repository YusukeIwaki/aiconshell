# frozen_string_literal: true

require_relative "ai_test_helper"

# Shared fakes for the Authentication lane. All challenge URLs, query values
# and user codes below are obviously-fake placeholders (never real
# transcripts): only the official host/path shapes are real.
module AuthenticationTestSupport
  # Placeholder challenges: official host/path, fake query and code values.
  CLAUDE_URL = "https://claude.com/cai/oauth/authorize?client_id=PLACEHOLDER&state=PLACEHOLDER"
  CODEX_URL = "https://auth.openai.com/codex/device"
  CODEX_URL_WITH_QUERY = "https://auth.openai.com/codex/device?request=PLACEHOLDER"
  MUSE_URL = "https://auth.meta.com/oauth/device/?code=PLACEHOLDER"

  CODEX_CODE = "TEST-CODE1"
  MUSE_CODE = "DEMO01X9"
  PASTE_CODE = "UNIT-TEST-PASTE-0#TEST-STATE"

  module_function

  def make_auth_runner(root, process_runner: nil, sessions: nil, clock: nil, **config_overrides)
    bin = AiTestSupport.make_bin(root, %w[claude codex muse])
    config = AiTestSupport.make_config(root, bin: bin, **config_overrides)
    AiTestSupport.with_env("PATH" => bin) do
      factory = FakeSessionFactory.new(Array(sessions))
      runner = Aiconshell::Ai::Authentication::Runner.new(
        config: config,
        process_runner: process_runner || FakeProcessRunner.new([FakeProcessRunner.ok(stdout: JSON.generate({"loggedIn"=>true,"authMethod"=>"claude.ai","apiProvider"=>"firstParty"}))]),
        session_factory: factory,
        clock: clock || FakeClock.new
      )
      yield runner, factory, config
    end
  end

  # Records emissions; optionally raises to simulate a UI failure.
  def challenge_sink(raise_on: nil)
    received = []
    calls = 0
    sink = lambda do |challenge|
      calls += 1
      raise "sink boom" if raise_on == calls

      received << challenge
      nil
    end
    [sink, received]
  end

  # Returns nil `blanks` times, then `code` once, then nil forever.
  def code_input(code, blanks: 0)
    calls = 0
    delivered = false
    input = lambda do
      calls += 1
      if calls <= blanks || delivered
        nil
      else
        delivered = true
        code
      end
    end
    [input, -> { calls }]
  end

  def cancel_after(calls_before_true)
    calls = 0
    cancelled = lambda do
      calls += 1
      calls > calls_before_true
    end
    [cancelled, -> { calls }]
  end
end

# Manual monotonic clock. Fake sessions advance it from wait_output to
# simulate blocking without real sleeping.
class FakeClock
  def initialize(now = 1000.0)
    @now = now
  end

  def call
    @now
  end

  def advance(by)
    @now += by
  end
end

# Scriptable stand-in for Authentication::Session. Serves one scripted chunk
# per read_available call, then reports the child exited (unless keep_alive).
class FakeAuthSession
  attr_reader :argv, :env, :cwd, :stdin_writes, :terminated_with, :close_count, :stdin_closed

  def initialize(script = [], exit_status: 0, keep_alive: false, clock: nil)
    @chunks = script.map do |entry|
      kind, text = entry
      kind == :stderr ? ["", text] : [text, ""]
    end
    @exit_status_value = exit_status
    @keep_alive = keep_alive
    @clock = clock
    @terminated = false
    @terminated_with = nil
    @close_count = 0
    @stdin_closed = false
    @stdin_writes = []
  end

  def terminated?
    @terminated
  end

  def alive?
    return false if @terminated

    @keep_alive ? true : !@chunks.empty?
  end

  def exit_status
    return nil if alive?

    @terminated ? nil : @exit_status_value
  end

  def wait_output(timeout)
    @clock&.advance(timeout)
    true
  end

  def read_available
    return ["", ""] if @terminated
    return ["", ""] if @chunks.empty?

    @chunks.shift
  end

  def write_stdin(data)
    raise IOError, "stdin is closed" if @terminated || @stdin_closed

    @stdin_writes << data
    data.bytesize
  end

  def close_stdin
    @stdin_closed = true
  end

  def terminate(grace:)
    @terminated = true
    @terminated_with = grace
    close
    nil
  end

  def close
    @close_count += 1
  end
end

# Records spawn arguments and serves queued FakeAuthSessions (or a behavior
# lambda, which may raise to simulate spawn failure).
class FakeSessionFactory
  attr_reader :spawns

  def initialize(sessions = [], &behavior)
    @sessions = sessions.dup
    @behavior = behavior
    @spawns = []
  end

  def spawn(argv:, env:, cwd:)
    record = { argv: argv, env: env, cwd: cwd }
    @spawns << record
    if @behavior
      session = @behavior.call(record)
      record[:session] = session
      return session
    end
    raise "FakeSessionFactory: no scripted session left" if @sessions.empty?

    session = @sessions.shift
    session.instance_variable_set(:@argv, argv)
    session.instance_variable_set(:@env, env)
    session.instance_variable_set(:@cwd, cwd)
    record[:session] = session
    session
  end
end
