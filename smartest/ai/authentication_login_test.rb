# frozen_string_literal: true

require_relative "authentication_support"

Auth = Aiconshell::Ai::Authentication unless defined?(Auth)
Support = AuthenticationTestSupport

test("auth login completes claude with a pasted code over stdin only") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new(
      [
        [:stdout, "Sign in at #{Support::CLAUDE_URL}\n"],
        [:stdout, "Paste code here if prompted > "]
      ],
      exit_status: 0, clock: clock
    )
    sink, received = Support.challenge_sink
    input, input_calls = Support.code_input(Support::PASTE_CODE)
    Support.make_auth_runner(root, sessions: [session], clock: clock) do |runner, factory, config|
      result = runner.login(provider: "claude", on_challenge: sink, input: input, cancelled: -> { false })
      expect(result).to eq({ "state" => "connected", "error_code" => nil })

      spawn = factory.spawns.fetch(0)
      expect(spawn[:argv]).to eq([spawn[:argv].first, "auth", "login", "--claudeai"])
      expect(spawn[:argv].join(" ").include?(Support::PASTE_CODE)).to eq(false)
      expect(spawn[:env]).to eq(Aiconshell::Ai::ChildEnv.build(provider: "claude", config: config))
      expect(spawn[:cwd]).to eq(config.auth_dir_for("claude"))

      expect(session.stdin_writes).to eq(["#{Support::PASTE_CODE}\n"])
      expect(session.stdin_closed).to eq(true)
      expect(input_calls.call >= 1).to eq(true)

      expect(received.size).to eq(2)
      expect(received[0]).to eq(
        { "verification_uri" => Support::CLAUDE_URL, "user_code" => nil, "input_required" => false }
      )
      expect(received[1]).to eq(
        { "verification_uri" => Support::CLAUDE_URL, "user_code" => nil, "input_required" => true }
      )
      expect(session.terminated?).to eq(false)
      expect(session.close_count >= 1).to eq(true)
    end
  end
end

test("auth login reassembles a chunk-split claude url before emitting") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    url = Support::CLAUDE_URL
    session = FakeAuthSession.new(
      [
        [:stdout, "Visit #{url[0, 20]}"],
        [:stdout, url[20, 30]],
        [:stdout, "#{url[50..]}\nPaste code here if prompted > "]
      ],
      exit_status: 0, clock: clock
    )
    sink, received = Support.challenge_sink
    input, _calls = Support.code_input(Support::PASTE_CODE)
    Support.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
      expect(runner.login(provider: "claude", on_challenge: sink, input: input, cancelled: -> { false }))
        .to eq({ "state" => "connected", "error_code" => nil })
      uris = received.map { |challenge| challenge["verification_uri"] }.uniq
      expect(uris).to eq([url])
    end
  end
end

test("auth login strips ansi styling split across chunks") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new(
      [
        [:stdout, "Visit \e[3"],
        [:stdout, "4m#{Support::CODEX_URL}\e[0m\nEnter code #{Support::CODEX_CODE}\n"]
      ],
      exit_status: 0, clock: clock
    )
    sink, received = Support.challenge_sink
    Support.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
      expect(runner.login(provider: "codex", on_challenge: sink, input: -> { nil }, cancelled: -> { false }))
        .to eq({ "state" => "connected", "error_code" => nil })
      expect(received.last).to eq(
        { "verification_uri" => Support::CODEX_URL, "user_code" => Support::CODEX_CODE, "input_required" => false }
      )
    end
  end
end

test("auth login completes codex device flow without stdin input") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new(
      [[:stdout, "Go to #{Support::CODEX_URL_WITH_QUERY}\nEnter code #{Support::CODEX_CODE}\nWaiting for approval\n"]],
      exit_status: 0, clock: clock
    )
    sink, received = Support.challenge_sink
    input_calls = 0
    input = -> { input_calls += 1 }
    cancelled_calls = 0
    cancelled = -> { cancelled_calls += 1; false }
    Support.make_auth_runner(root, sessions: [session], clock: clock) do |runner, factory, config|
      result = runner.login(provider: "codex", on_challenge: sink, input: input, cancelled: cancelled)
      expect(result).to eq({ "state" => "connected", "error_code" => nil })

      spawn = factory.spawns.fetch(0)
      expect(spawn[:argv]).to eq(
        [spawn[:argv].first, "login", "--device-auth",
          "-c", 'forced_login_method="chatgpt"',
          "-c", 'cli_auth_credentials_store="file"']
      )
      joined = spawn[:argv].join(" ")
      expect(joined.include?("--with-api-key")).to eq(false)
      expect(joined.include?("--with-access-token")).to eq(false)
      expect(spawn[:env]).to eq(Aiconshell::Ai::ChildEnv.build(provider: "codex", config: config))

      expect(session.stdin_writes).to eq([])
      expect(input_calls).to eq(0)
      expect(cancelled_calls >= 1).to eq(true)
      expect(received).to eq(
        [{
          "verification_uri" => Support::CODEX_URL_WITH_QUERY,
          "user_code" => Support::CODEX_CODE,
          "input_required" => false
        }]
      )
    end
  end
end

test("auth login re-emits when the muse user code arrives late") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new(
      [
        [:stdout, "Approve in your browser: #{Support::MUSE_URL}\n"],
        [:stdout, "Your user code is #{Support::MUSE_CODE}\n"]
      ],
      exit_status: 0, clock: clock
    )
    sink, received = Support.challenge_sink
    Support.make_auth_runner(root, sessions: [session], clock: clock) do |runner, factory, _config|
      expect(runner.login(provider: "muse", on_challenge: sink, input: -> { nil }, cancelled: -> { false }))
        .to eq({ "state" => "connected", "error_code" => nil })
      expect(factory.spawns.fetch(0)[:argv][1..]).to eq(["login"])
      expect(received).to eq(
        [
          { "verification_uri" => Support::MUSE_URL, "user_code" => nil, "input_required" => false },
          { "verification_uri" => Support::MUSE_URL, "user_code" => Support::MUSE_CODE, "input_required" => false }
        ]
      )
    end
  end
end

test("auth login connects quietly when the cli is already logged in") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new([[:stdout, "Already signed in\n"]], exit_status: 0, clock: clock)
    sink, received = Support.challenge_sink
    Support.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
      expect(runner.login(provider: "codex", on_challenge: sink, input: -> { nil }, cancelled: -> { false }))
        .to eq({ "state" => "connected", "error_code" => nil })
      expect(received).to eq([])
    end
  end
end

test("auth login reads challenges from stderr too") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new(
      [[:stderr, "Visit #{Support::CODEX_URL}\ncode #{Support::CODEX_CODE}\n"]],
      exit_status: 0, clock: clock
    )
    sink, received = Support.challenge_sink
    Support.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
      expect(runner.login(provider: "codex", on_challenge: sink, input: -> { nil }, cancelled: -> { false }))
        .to eq({ "state" => "connected", "error_code" => nil })
      expect(received.size).to eq(1)
      expect(received.first["verification_uri"]).to eq(Support::CODEX_URL)
    end
  end
end

test("auth login rejects forged verification urls") do
  AiTestSupport.with_tmpdir do |root|
    {
      "https://evil.example/sign-in" => "codex",
      "http://auth.openai.com/codex/device" => "codex",
      "https://auth.openai.com@evil.example/codex/device" => "codex",
      "https://auth.openai.com:8443/codex/device" => "codex",
      "https://auth.openai.com/other/path" => "codex",
      "https://auth.openai.com/codex/device#frag" => "codex",
      "https://evil-claude.com/cai/oauth/authorize" => "claude",
      "https://auth.meta.com.evil.example/oauth/device/" => "muse"
    }.each do |forged, provider|
      clock = FakeClock.new
      session = FakeAuthSession.new([[:stdout, "Visit #{forged}\n"]], exit_status: 0, clock: clock)
      sink, received = Support.challenge_sink
      Support.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
        result = runner.login(provider: provider, on_challenge: sink, input: -> { nil }, cancelled: -> { false })
        expect(result).to eq({ "state" => "failed", "error_code" => "challenge_rejected" })
        expect(received).to eq([])
        expect(result.inspect.include?(forged)).to eq(false)
        expect(session.terminated?).to eq(true)
      end
    end
  end
end

test("auth login rejects api-key pivots mid-flow") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new(
      [[:stdout, "Visit #{Support::CODEX_URL}\nPlease sign in with an API key instead\n"]],
      exit_status: 0, clock: clock
    )
    sink, received = Support.challenge_sink
    Support.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
      expect(runner.login(provider: "codex", on_challenge: sink, input: -> { nil }, cancelled: -> { false }))
        .to eq({ "state" => "failed", "error_code" => "auth_rejected" })
      expect(session.terminated?).to eq(true)
      expect(received).to eq([])
    end
  end
end

test("auth login classifies nonzero exits without leaking output") do
  AiTestSupport.with_tmpdir do |root|
    {
      "Login failed: access denied (trace 12345)" => "auth_rejected",
      "error: device code expired, restart login" => "expired",
      "some baffling new banner" => "unexpected_output"
    }.each do |text, expected|
      clock = FakeClock.new
      session = FakeAuthSession.new([[:stdout, "#{text}\n"]], exit_status: 1, clock: clock)
      sink, _received = Support.challenge_sink
      Support.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
        result = runner.login(provider: "codex", on_challenge: sink, input: -> { nil }, cancelled: -> { false })
        if expected == "expired"
          expect(result).to eq({ "state" => "expired", "error_code" => nil })
        else
          expect(result).to eq({ "state" => "failed", "error_code" => expected })
        end
        expect(result.inspect.include?("12345")).to eq(false)
      end
    end
  end
end

test("auth login honors cancellation and deadlines with cleanup") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    hanging = FakeAuthSession.new([], keep_alive: true, clock: clock)
    cancelled, _calls = Support.cancel_after(2)
    sink, _received = Support.challenge_sink
    Support.make_auth_runner(root, sessions: [hanging], clock: clock) do |runner, _factory, _config|
      expect(runner.login(provider: "muse", timeout: 60, on_challenge: sink, input: -> { nil }, cancelled: cancelled))
        .to eq({ "state" => "cancelled", "error_code" => nil })
      expect(hanging.terminated?).to eq(true)
      expect(hanging.close_count >= 1).to eq(true)
    end

    clock2 = FakeClock.new
    stuck = FakeAuthSession.new([], keep_alive: true, clock: clock2)
    sink2, _received2 = Support.challenge_sink
    Support.make_auth_runner(root, sessions: [stuck], clock: clock2) do |runner, _factory, _config|
      expect(runner.login(provider: "muse", timeout: 5, on_challenge: sink2, input: -> { nil }, cancelled: -> { false }))
        .to eq({ "state" => "expired", "error_code" => nil })
      expect(stuck.terminated?).to eq(true)
      expect(stuck.close_count >= 1).to eq(true)
    end
  end
end

test("auth login skips spawning when already cancelled") do
  AiTestSupport.with_tmpdir do |root|
    Support.make_auth_runner(root) do |runner, factory, _config|
      sink, _received = Support.challenge_sink
      expect(runner.login(provider: "claude", on_challenge: sink, input: -> { nil }, cancelled: -> { true }))
        .to eq({ "state" => "cancelled", "error_code" => nil })
      expect(factory.spawns).to eq([])
    end
  end
end

test("auth login maps callback failures to fixed classifications") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new(
      [[:stdout, "Visit #{Support::CODEX_URL}\n"]], keep_alive: true, clock: clock
    )
    sink, _received = Support.challenge_sink(raise_on: 1)
    Support.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
      expect(runner.login(provider: "codex", on_challenge: sink, input: -> { nil }, cancelled: -> { false }))
        .to eq({ "state" => "failed", "error_code" => "callback_failed" })
      expect(session.terminated?).to eq(true)
    end

    clock2 = FakeClock.new
    prompt = FakeAuthSession.new(
      [[:stdout, "Visit #{Support::CLAUDE_URL}\nPaste code here if prompted > "]],
      keep_alive: true, clock: clock2
    )
    bad_input = -> { raise "ui boom" }
    sink2, _received2 = Support.challenge_sink
    Support.make_auth_runner(root, sessions: [prompt], clock: clock2) do |runner, _factory, _config|
      expect(runner.login(provider: "claude", on_challenge: sink2, input: bad_input, cancelled: -> { false }))
        .to eq({ "state" => "failed", "error_code" => "input_failed" })
      expect(prompt.terminated?).to eq(true)
    end

    [123, "", "  ", "bad\0code", "x" * 257].each do |bad_code|
      clock3 = FakeClock.new
      session3 = FakeAuthSession.new(
        [[:stdout, "Visit #{Support::CLAUDE_URL}\nPaste code here if prompted > "]],
        keep_alive: true, clock: clock3
      )
      sink3, _received3 = Support.challenge_sink
      Support.make_auth_runner(root, sessions: [session3], clock: clock3) do |runner, _factory, _config|
        result = runner.login(provider: "claude", on_challenge: sink3, input: -> { bad_code }, cancelled: -> { false })
        expect(result).to eq({ "state" => "failed", "error_code" => "input_failed" })
        expect(result.inspect.include?("bad")).to eq(false)
      end
    end

    clock4 = FakeClock.new
    session4 = FakeAuthSession.new([], keep_alive: true, clock: clock4)
    sink4, _received4 = Support.challenge_sink
    Support.make_auth_runner(root, sessions: [session4], clock: clock4) do |runner, _factory, _config|
      exploding = -> { raise "cancel boom" }
      expect(runner.login(provider: "codex", on_challenge: sink4, input: -> { nil }, cancelled: exploding))
        .to eq({ "state" => "failed", "error_code" => "cancel_check_failed" })
    end
  end
end

test("auth login strips padding around the pasted code") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new(
      [[:stdout, "Visit #{Support::CLAUDE_URL}\nPaste code here if prompted > "]],
      exit_status: 0, clock: clock
    )
    sink, _received = Support.challenge_sink
    Support.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
      expect(runner.login(provider: "claude", on_challenge: sink, input: -> { "  #{Support::PASTE_CODE}\n" }, cancelled: -> { false }))
        .to eq({ "state" => "connected", "error_code" => nil })
      expect(session.stdin_writes).to eq(["#{Support::PASTE_CODE}\n"])
    end
  end
end

test("auth login enforces the output cap") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new([[:stdout, "y" * 5000]], keep_alive: true, clock: clock)
    sink, _received = Support.challenge_sink
    Support.make_auth_runner(root, sessions: [session], clock: clock, max_output_bytes: 1024) do |runner, _factory, _config|
      expect(runner.login(provider: "codex", on_challenge: sink, input: -> { nil }, cancelled: -> { false }))
        .to eq({ "state" => "failed", "error_code" => "output_capped" })
      expect(session.terminated?).to eq(true)
    end
  end
end

test("auth login validates provider, timeout and callbacks without spawning") do
  AiTestSupport.with_tmpdir do |root|
    Support.make_auth_runner(root) do |runner, factory, _config|
      sink, _received = Support.challenge_sink
      expect(runner.login(provider: "nope", on_challenge: sink, input: -> { nil }, cancelled: -> { false }))
        .to eq({ "state" => "failed", "error_code" => "invalid_provider" })
      ["x", -1, 0, Float::NAN, Float::INFINITY].each do |timeout|
        expect(runner.login(provider: "codex", timeout: timeout, on_challenge: sink, input: -> { nil }, cancelled: -> { false }))
          .to eq({ "state" => "failed", "error_code" => "invalid_argument" })
      end
      expect(runner.login(provider: "codex", on_challenge: nil, input: -> { nil }, cancelled: -> { false }))
        .to eq({ "state" => "failed", "error_code" => "invalid_argument" })
      expect(runner.login(provider: "codex", on_challenge: sink, input: "code", cancelled: -> { false }))
        .to eq({ "state" => "failed", "error_code" => "invalid_argument" })
      expect(factory.spawns).to eq([])
    end
  end
end

test("auth login reports unavailable and spawn failure") do
  AiTestSupport.with_tmpdir do |root|
    bin = AiTestSupport.make_bin(root, %w[claude])
    config = AiTestSupport.make_config(root, bin: bin)
    AiTestSupport.with_env("PATH" => bin) do
      runner = Auth::Runner.new(config: config)
      sink, _received = Support.challenge_sink
      expect(runner.login(provider: "muse", on_challenge: sink, input: -> { nil }, cancelled: -> { false }))
        .to eq({ "state" => "unavailable", "error_code" => nil })
    end

    factory = FakeSessionFactory.new { |_spawn| raise Errno::ENOENT, "gone" }
    bin2 = AiTestSupport.make_bin(root, %w[codex])
    config2 = AiTestSupport.make_config(root, bin: bin2)
    AiTestSupport.with_env("PATH" => bin2) do
      runner = Auth::Runner.new(config: config2, session_factory: factory)
      sink, _received = Support.challenge_sink
      result = runner.login(provider: "codex", on_challenge: sink, input: -> { nil }, cancelled: -> { false })
      expect(result).to eq({ "state" => "failed", "error_code" => "spawn_failed" })
      expect(result.inspect.include?("gone")).to eq(false)
    end
  end
end

test("auth login truncates codex challenge urls at sentence punctuation") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new(
      [[:stdout, "(see #{Support::CODEX_URL}.)\ncode #{Support::CODEX_CODE}\n"]],
      exit_status: 0, clock: clock
    )
    sink, received = Support.challenge_sink
    Support.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
      expect(runner.login(provider: "codex", on_challenge: sink, input: -> { nil }, cancelled: -> { false }))
        .to eq({ "state" => "connected", "error_code" => nil })
      expect(received.first["verification_uri"]).to eq(Support::CODEX_URL)
    end
  end
end
