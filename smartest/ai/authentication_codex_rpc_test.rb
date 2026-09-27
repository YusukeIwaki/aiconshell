# frozen_string_literal: true
require_relative "authentication_support"

module CodexAuthFixtures
  module_function
  def session(messages, clock:, **options)
    FakeAuthSession.new(messages.map { |message| [:stdout, "#{JSON.generate(message)}\n"] }, clock: clock, **options)
  end
  def initialized
    { id: 1, result: { userAgent: "test" } }
  end
  def started(**changes)
    { id: 3, result: { type: "chatgptDeviceCode", loginId: "TEST-LOGIN-ID",
                      verificationUrl: AuthenticationTestSupport::CODEX_URL, userCode: "TEST-CODE1" }.merge(changes) }
  end
  def completed(**changes)
    { method: "account/login/completed", params: { loginId: "TEST-LOGIN-ID", success: true, error: nil }.merge(changes) }
  end
  def account(value = { type: "chatgpt", email: nil, planType: "unknown" })
    { id: 2, result: { account: value, requiresOpenaiAuth: true, workspaceRouting: nil } }
  end
  def login(messages, **options)
    AiTestSupport.with_tmpdir do |root|
      clock = FakeClock.new
      session = self.session(messages, clock: clock)
      AuthenticationTestSupport.make_auth_runner(root, sessions: [session], clock: clock) do |runner, factory, config|
        challenges = []
        result = runner.login(provider: "codex", input: -> { raise "must not read input" },
          on_challenge: ->(value) { challenges << value }, cancelled: -> { false }, **options)
        yield result, challenges, session, factory, config
      end
    end
  end
end

CF = CodexAuthFixtures unless defined?(CF)

test("codex structured login verifies matching completion and ChatGPT account") do
  CF.login([CF.initialized, CF.started, CF.completed, CF.account]) do |result, challenges, session, factory, config|
    expect(result).to eq({ "state" => "connected", "error_code" => nil })
    expect(challenges).to eq([{ "verification_uri" => AuthenticationTestSupport::CODEX_URL,
      "user_code" => "TEST-CODE1", "input_required" => false }])
    spawn = factory.spawns.first
    expect(spawn[:argv][1..]).to eq(Aiconshell::Ai::Authentication::CodexRpc::ARGV)
    expect(spawn[:env]).to eq(Aiconshell::Ai::ChildEnv.build(provider: "codex", config: config))
    writes = session.stdin_writes.map { |line| JSON.parse(line) }
    expect(writes.map { |row| row["method"] }).to eq(%w[initialize initialized account/login/start account/read])
    expect(writes.any? { |row| row.key?("jsonrpc") }).to eq(false)
    expect(writes[2]["params"]).to eq({ "type" => "chatgptDeviceCode" })
    expect(writes[3]["params"]).to eq({ "refreshToken" => false })
    expect(session.stdin_closed).to eq(true)
    expect(session.terminated?).to eq(true)
  end
end

test("codex supports completion notification arriving before start response") do
  CF.login([CF.initialized, CF.completed, CF.started, CF.account]) do |result, _challenges, _session, _factory, _config|
    expect(result["state"]).to eq("connected")
  end
end

test("codex rejects unrelated completions and account-updated-only signals") do
  [[CF.completed(loginId: "OTHER-LOGIN")], [{ method: "account/updated", params: { authMode: "chatgpt" } }]].each do |events|
    CF.login([CF.initialized, CF.started, *events]) do |result, _challenges, session, _factory, _config|
      expect(result).to eq({ "state" => "failed", "error_code" => "unexpected_output" })
      expect(session.stdin_writes.map { |line| JSON.parse(line)["method"] }.include?("account/read")).to eq(false)
      cancel = session.stdin_writes.map { |line| JSON.parse(line) }.find { |row| row["method"] == "account/login/cancel" }
      expect(cancel["params"]).to eq({ "loginId" => "TEST-LOGIN-ID" })
    end
  end
end

test("codex account-read rejects non-subscription and malformed accounts") do
  [nil, { type: "apiKey" }, { type: "amazonBedrock" }, { type: "future" }, { type: "chatgpt" }].each do |account|
    CF.login([CF.initialized, CF.started, CF.completed, CF.account(account)]) do |result, _challenges, _session, _factory, _config|
      expect(result["state"]).to eq(account.nil? ? "disconnected" : "failed")
    end
  end
end

test("codex failed or malformed completion cannot authenticate") do
  [{ success: false, error: "FAKE-SECRET-ERROR" }, { success: "true" }, { success: true, error: "FAKE-SECRET" }].each do |changes|
    CF.login([CF.initialized, CF.started, CF.completed(**changes), CF.account]) do |result, _challenges, _session, _factory, _config|
      expect(result["state"]).to eq("failed")
      expect(result.inspect.include?("FAKE-SECRET")).to eq(false)
    end
  end
end

test("codex device URLs and user codes are strictly validated before callbacks") do
  ["https://evil.example/device", "http://auth.openai.com/codex/device",
   "https://auth.openai.com:8443/codex/device", "https://auth.openai.com/other",
   "https://auth.openai.com@evil.example/codex/device", "https://auth.openai.com/codex/device#frag"].each do |url|
    CF.login([CF.initialized, CF.started(verificationUrl: url)]) do |result, challenges, session, _factory, _config|
      expect(result["error_code"]).to eq("challenge_rejected")
      expect(challenges).to eq([])
      expect(session.stdin_writes.last.include?("account/login/cancel")).to eq(true)
    end
  end
  [nil, "", "x" * 65, "BAD\nCODE"].each do |code|
    CF.login([CF.initialized, CF.started(userCode: code)]) do |result, challenges, _session, _factory, _config|
      expect(result["error_code"]).to eq("challenge_rejected")
      expect(challenges).to eq([])
    end
  end
end

test("codex cancellation sends login cancel with the exact opaque id") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = CF.session([CF.initialized, CF.started], clock: clock, keep_alive: true)
    AuthenticationTestSupport.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
      cancelled = false
      result = runner.login(provider: "codex", input: -> { nil }, on_challenge: ->(_c) { cancelled = true }, cancelled: -> { cancelled })
      expect(result["state"]).to eq("cancelled")
      cancel = JSON.parse(session.stdin_writes.last)
      expect(cancel["method"]).to eq("account/login/cancel")
      expect(cancel["params"]).to eq({ "loginId" => "TEST-LOGIN-ID" })
      expect(session.terminated?).to eq(true)
    end
  end
end

test("codex callback exceptions are classified and cancel the pending login") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = CF.session([CF.initialized, CF.started], clock: clock)
    AuthenticationTestSupport.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
      result = runner.login(provider: "codex", input: -> { nil }, on_challenge: ->(_c) { raise "FAKE-SECRET" }, cancelled: -> { false })
      expect(result).to eq({ "state" => "failed", "error_code" => "callback_failed" })
      expect(session.stdin_writes.last.include?("account/login/cancel")).to eq(true)
    end
  end
end

test("codex status uses structured account read and ignores human status text") do
  AiTestSupport.with_tmpdir do |root|
    [CF.account(nil), CF.account, { id: 2, result: { requiresOpenaiAuth: true } }].each_with_index do |account, index|
      clock = FakeClock.new
      session = CF.session([CF.initialized, account], clock: clock)
      AuthenticationTestSupport.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
        expect(runner.status(provider: "codex")["state"]).to eq(%w[disconnected connected failed][index])
        expect(session.stdin_writes.any? { |line| line.include?("account/login/start") }).to eq(false)
      end
    end
    clock = FakeClock.new
    text = FakeAuthSession.new([[:stdout, "Logged in using ChatGPT\n"]], clock: clock)
    AuthenticationTestSupport.make_auth_runner(root, sessions: [text], clock: clock) do |runner, _factory, _config|
      expect(runner.status(provider: "codex")["state"]).to eq("failed")
    end
  end
end

test("codex silent server expires and cleans up") do
  CF.login([], timeout: 1) do |result, _challenges, session, _factory, _config|
    expect(result["state"]).to eq("failed") # child exited without protocol
    expect(session.terminated?).to eq(true)
  end
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new([], clock: clock, keep_alive: true)
    AuthenticationTestSupport.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
      expect(runner.login(provider: "codex", timeout: 1, on_challenge: ->(_c) {}, input: -> { nil }, cancelled: -> { false })["state"]).to eq("expired")
      expect(session.terminated?).to eq(true)
    end
  end
end
