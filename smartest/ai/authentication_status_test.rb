# frozen_string_literal: true

require_relative "authentication_support"

Auth = Aiconshell::Ai::Authentication unless defined?(Auth)

# --- status: claude ---

test("auth status maps claude logged-in JSON to connected") do
  AiTestSupport.with_tmpdir do |root|
    body = JSON.generate({ "loggedIn" => true, "authMethod" => "claude.ai", "apiProvider" => "firstParty", "configDirectory" => "/private/x" })
    process = FakeProcessRunner.new([FakeProcessRunner.ok(stdout: body)])
    AuthenticationTestSupport.make_auth_runner(root, process_runner: process) do |runner, _factory, _config|
      expect(runner.status(provider: "claude")).to eq({ "state" => "connected", "error_code" => nil })
    end
  end
end

test("auth status maps claude logged-out JSON to disconnected") do
  AiTestSupport.with_tmpdir do |root|
    body = JSON.generate({ "loggedIn" => false, "authMethod" => "none", "apiProvider" => "firstParty" })
    process = FakeProcessRunner.new([FakeProcessRunner.ok(stdout: body, exit_status: 1)])
    AuthenticationTestSupport.make_auth_runner(root, process_runner: process) do |runner, _factory, _config|
      expect(runner.status(provider: "claude")).to eq({ "state" => "disconnected", "error_code" => nil })
    end
  end
end

test("auth status rejects claude api-key and console methods") do
  AiTestSupport.with_tmpdir do |root|
    %w[apiKey API_KEY console].each do |method|
      body = JSON.generate({ "loggedIn" => true, "authMethod" => method, "apiProvider" => "firstParty" })
      process = FakeProcessRunner.new([FakeProcessRunner.ok(stdout: body)])
      AuthenticationTestSupport.make_auth_runner(root, process_runner: process) do |runner, _factory, _config|
        expect(runner.status(provider: "claude")).to eq({ "state" => "failed", "error_code" => "auth_rejected" })
      end
    end
  end
end

test("auth status fails safe on claude garbage output") do
  AiTestSupport.with_tmpdir do |root|
    ["not json at all", "", JSON.generate({ "loggedIn" => "yes" }), JSON.generate([1, 2])].each do |stdout|
      process = FakeProcessRunner.new([FakeProcessRunner.ok(stdout: stdout, exit_status: 1)])
      AuthenticationTestSupport.make_auth_runner(root, process_runner: process) do |runner, _factory, _config|
        result = runner.status(provider: "claude")
        expect(result).to eq({ "state" => "failed", "error_code" => "unexpected_output" })
        expect(result.inspect.include?(stdout.strip)).to eq(false) unless stdout.strip.empty?
      end
    end
  end
end

test("auth status spawns claude with fixed argv, allowlist env and auth cwd") do
  AiTestSupport.with_tmpdir do |root|
    body = JSON.generate({ "loggedIn" => false, "authMethod" => "none", "apiProvider" => "firstParty" })
    process = FakeProcessRunner.new([FakeProcessRunner.ok(stdout: body, exit_status: 1)])
    AiTestSupport.with_env("DATABASE_URL" => "postgres://secret/db", "OPENAI_API_KEY" => "sk-secret") do
      AuthenticationTestSupport.make_auth_runner(root, process_runner: process) do |runner, _factory, config|
        runner.status(provider: "claude")
        call = process.calls.fetch(0)
        expect(call[:argv]).to eq([call[:argv].first, "auth", "status", "--json"])
        expect(call[:argv].first.end_with?("claude")).to eq(true)
        expect(call[:env]).to eq(Aiconshell::Ai::ChildEnv.build(provider: "claude", config: config))
        expect(call[:env].key?("DATABASE_URL")).to eq(false)
        expect(call[:env].key?("OPENAI_API_KEY")).to eq(false)
        expect(call[:cwd]).to eq(config.auth_dir_for("claude"))
        expect(call[:stdin_data]).to be_nil
      end
    end
  end
end

# --- status: shared edges ---

test("auth status reports unavailable when the executable is missing") do
  AiTestSupport.with_tmpdir do |root|
    bin = AiTestSupport.make_bin(root, %w[claude]) # codex absent
    config = AiTestSupport.make_config(root, bin: bin)
    AiTestSupport.with_env("PATH" => bin) do
      runner = Auth::Runner.new(config: config)
      expect(runner.status(provider: "codex")).to eq({ "state" => "unavailable", "error_code" => nil })
    end
  end
end

test("auth status maps timeout, truncation and spawn failure") do
  AiTestSupport.with_tmpdir do |root|
    process = FakeProcessRunner.new([FakeProcessRunner.timeout])
    AuthenticationTestSupport.make_auth_runner(root, process_runner: process) do |runner, _factory, _config|
      expect(runner.status(provider: "claude")).to eq({ "state" => "failed", "error_code" => "timeout" })
    end

    truncated = Aiconshell::Ai::Result.new(
      stdout: "x", stderr: "", exit_status: 0,
      timed_out: false, stdout_truncated: true, stderr_truncated: false
    )
    process = FakeProcessRunner.new([truncated])
    AuthenticationTestSupport.make_auth_runner(root, process_runner: process) do |runner, _factory, _config|
      expect(runner.status(provider: "claude")).to eq({ "state" => "failed", "error_code" => "output_capped" })
    end

    failing = FakeProcessRunner.new { |_call| raise Errno::ENOENT, "gone" }
    AuthenticationTestSupport.make_auth_runner(root, process_runner: failing) do |runner, _factory, _config|
      expect(runner.status(provider: "claude")).to eq({ "state" => "failed", "error_code" => "spawn_failed" })
    end
  end
end

test("auth status rejects unknown providers without spawning") do
  AiTestSupport.with_tmpdir do |root|
    process = FakeProcessRunner.new
    AuthenticationTestSupport.make_auth_runner(root, process_runner: process) do |runner, factory, _config|
      [nil, "", "gpt", "CLAUDE", "claude "].each do |provider|
        expect(runner.status(provider: provider)).to eq({ "state" => "failed", "error_code" => "invalid_provider" })
      end
      expect(process.calls).to eq([])
      expect(factory.spawns).to eq([])
    end
  end
end

# --- status: muse via MSP account/read ---

def muse_account_script(state, clock, extra: {})
  init = JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "result" => { "serverInfo" => { "name" => "msp" } } })
  account = JSON.generate(
    { "jsonrpc" => "2.0", "id" => 2, "result" => { "credentialRequired" => true, "state" => state }.merge(extra) }
  )
  FakeAuthSession.new([[:stdout, "#{init}\n"], [:stdout, "#{account}\n"]], clock: clock)
end

test("auth status maps muse account states") do
  AiTestSupport.with_tmpdir do |root|
    {
      "accountLogin" => { "state" => "connected", "error_code" => nil },
      "loggedOut" => { "state" => "disconnected", "error_code" => nil },
      "envKey" => { "state" => "failed", "error_code" => "auth_rejected" },
      "apiKey" => { "state" => "failed", "error_code" => "auth_rejected" },
      "futureLane" => { "state" => "failed", "error_code" => "unexpected_output" },
      nil => { "state" => "failed", "error_code" => "unexpected_output" }
    }.each do |msp_state, expected|
      clock = FakeClock.new
      session = muse_account_script(msp_state, clock,
        extra: { "label" => "Fake User", "avatarUrl" => "https://example.invalid/a.png" })
      AuthenticationTestSupport.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
        result = runner.status(provider: "muse")
        expect(result).to eq(expected)
        expect(result.inspect.include?("Fake User")).to eq(false)
      end
    end
  end
end

test("auth status speaks initialize, initialized and account/read to muse serve") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = muse_account_script("loggedOut", clock)
    AuthenticationTestSupport.make_auth_runner(root, sessions: [session], clock: clock) do |runner, factory, config|
      expect(runner.status(provider: "muse")).to eq({ "state" => "disconnected", "error_code" => nil })

      spawn = factory.spawns.fetch(0)
      expect(spawn[:argv]).to eq(
        [spawn[:argv].first, "serve", "--no-session-log", "--disable-write", "--disable-shell"]
      )
      expect(spawn[:argv].first.end_with?("muse")).to eq(true)
      expect(spawn[:env]).to eq(Aiconshell::Ai::ChildEnv.build(provider: "muse", config: config))
      expect(spawn[:cwd]).to eq(config.auth_dir_for("muse"))

      writes = session.stdin_writes.map { |line| JSON.parse(line) }
      expect(writes.size).to eq(3)
      expect(writes[0]).to eq(
        { "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
          "params" => {
            "clientInfo" => { "name" => "aiconshell_auth", "version" => "0.1" },
            "capabilities" => { "experimentalApi" => true }
          } }
      )
      expect(writes[1]).to eq({ "jsonrpc" => "2.0", "method" => "initialized" })
      expect(writes[2]).to eq({ "jsonrpc" => "2.0", "id" => 2, "method" => "account/read" })
      expect(session.terminated?).to eq(true)
      expect(session.close_count >= 1).to eq(true)
    end
  end
end

test("auth status reaps muse serve after the answer and on failure") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    lingering = FakeAuthSession.new(
      [[:stdout, "#{JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "result" => {} })}\n"],
        [:stdout, "#{JSON.generate({ "jsonrpc" => "2.0", "id" => 2, "result" => { "state" => "loggedOut", "credentialRequired" => true } })}\n"]],
      keep_alive: true, clock: clock
    )
    AuthenticationTestSupport.make_auth_runner(root, sessions: [lingering], clock: clock) do |runner, _factory, config|
      expect(runner.status(provider: "muse")).to eq({ "state" => "disconnected", "error_code" => nil })
      expect(lingering.terminated?).to eq(true)
      expect(lingering.terminated_with).to eq(config.kill_grace_seconds)
      expect(lingering.close_count >= 1).to eq(true)
    end

    clock2 = FakeClock.new
    failing = FakeAuthSession.new(
      [[:stdout, "this is not json-rpc\n"]], exit_status: 1, clock: clock2
    )
    AuthenticationTestSupport.make_auth_runner(root, sessions: [failing], clock: clock2) do |runner, _factory, _config|
      expect(runner.status(provider: "muse")).to eq({ "state" => "failed", "error_code" => "unexpected_output" })
      expect(failing.close_count >= 1).to eq(true)
    end
  end
end

test("auth status times out a silent muse serve") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    silent = FakeAuthSession.new([], keep_alive: true, clock: clock)
    AuthenticationTestSupport.make_auth_runner(root, sessions: [silent], clock: clock) do |runner, _factory, _config|
      expect(runner.status(provider: "muse")).to eq({ "state" => "failed", "error_code" => "timeout" })
      expect(silent.terminated?).to eq(true)
    end
  end
end

test("auth status maps muse json-rpc errors and early exit") do
  AiTestSupport.with_tmpdir do |root|
    error = JSON.generate({ "jsonrpc" => "2.0", "id" => 2, "error" => { "code" => -32601, "message" => "nope" } })
    init = JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "result" => {} })
    clock = FakeClock.new
    session = FakeAuthSession.new([[:stdout, "#{init}\n"], [:stdout, "#{error}\n"]], clock: clock)
    AuthenticationTestSupport.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
      result = runner.status(provider: "muse")
      expect(result).to eq({ "state" => "failed", "error_code" => "unexpected_output" })
      expect(result.inspect.include?("nope")).to eq(false)
    end

    clock2 = FakeClock.new
    exited = FakeAuthSession.new([], exit_status: 1, clock: clock2)
    AuthenticationTestSupport.make_auth_runner(root, sessions: [exited], clock: clock2) do |runner, _factory, _config|
      expect(runner.status(provider: "muse")).to eq({ "state" => "failed", "error_code" => "unexpected_output" })
    end
  end
end
