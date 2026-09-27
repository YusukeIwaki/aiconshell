# frozen_string_literal: true
require_relative "authentication_support"
require "rbconfig"

Auth = Aiconshell::Ai::Authentication unless defined?(Auth)

test("claude status requires exact subscription fields and a successful exit") do
  AiTestSupport.with_tmpdir do |root|
    valid = { "loggedIn" => true, "authMethod" => "claude.ai", "apiProvider" => "firstParty" }
    cases = [[valid, 1], [valid.except("apiProvider"), 0], [valid.except("authMethod"), 0]]
    %w[oauth_token api_key api_key_helper third_party oauth unknown].each do |method|
      cases << [valid.merge("authMethod" => method), 0]
    end
    cases << [valid.merge("apiProvider" => "thirdParty"), 0]
    cases.each do |body, exit_code|
      process = FakeProcessRunner.new([FakeProcessRunner.ok(stdout: JSON.generate(body), exit_status: exit_code)])
      AuthenticationTestSupport.make_auth_runner(root, process_runner: process) do |runner, _factory, _config|
        expect(runner.status(provider: "claude")["state"]).to eq("failed")
      end
    end
  end
end

test("successful claude login exit still requires subscription status") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new([], exit_status: 0, clock: clock)
    process = FakeProcessRunner.new([FakeProcessRunner.ok(stdout: JSON.generate({loggedIn: false, authMethod: "none", apiProvider: "firstParty"}), exit_status: 1)])
    AuthenticationTestSupport.make_auth_runner(root, sessions: [session], process_runner: process, clock: clock) do |runner, _factory, _config|
      result = runner.login(provider: "claude", on_challenge: ->(_c) {}, input: -> { nil }, cancelled: -> { false })
      expect(result["state"]).to eq("disconnected")
      expect(process.calls.size).to eq(1)
    end
  end
end

test("cancel or deadline during post-login confirmation wins over connected") do
  [:cancel, :deadline].each do |mode|
    AiTestSupport.with_tmpdir do |root|
      clock = FakeClock.new
      cancelled = false
      session = FakeAuthSession.new([], exit_status: 0, clock: clock)
      process = FakeProcessRunner.new do |_call|
        mode == :cancel ? cancelled = true : clock.advance(50)
        FakeProcessRunner.ok(stdout: JSON.generate({loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty"}))
      end
      AuthenticationTestSupport.make_auth_runner(root, sessions: [session], process_runner: process, clock: clock) do |runner, _factory, _config|
        result = runner.login(provider: "claude", timeout: 10, on_challenge: ->(_c) {}, input: -> { nil }, cancelled: -> { cancelled })
        expect(result["state"]).to eq(mode == :cancel ? "cancelled" : "expired")
      end
    end
  end
end

test("muse account read requires its credentialRequired boolean") do
  [nil, "true", 1].each do |invalid|
    AiTestSupport.with_tmpdir do |root|
      clock = FakeClock.new
      session = FakeAuthSession.new([
        [:stdout, "#{JSON.generate({id: 1, result: {}})}\n"],
        [:stdout, "#{JSON.generate({id: 2, result: {state: "accountLogin", credentialRequired: invalid}})}\n"]
      ], clock: clock)
      AuthenticationTestSupport.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
        expect(runner.status(provider: "muse")["state"]).to eq("failed")
        expect(session.stdin_closed).to eq(true)
      end
    end
  end
end

test("subscription OAuth scope text is not an API-key mode switch") do
  url = "https://claude.com/cai/oauth/authorize?scope=org%3Acreate_api_key&state=TEST-STATE"
  scanner = Auth::Scanner.new("claude")
  scanner.feed("Visit #{url}\nPaste code here if prompted > ")
  expect(scanner.api_key_hit?).to eq(false)
  expect(scanner.challenge["verification_uri"]).to eq(url)
  scanner.feed("\nUse an API key instead\n")
  expect(scanner.api_key_hit?).to eq(true)
end

test("login accepts full code and state up to 4096 bytes over stdin only") do
  AiTestSupport.with_tmpdir do |root|
    clock = FakeClock.new
    session = FakeAuthSession.new([[:stdout, "#{AuthenticationTestSupport::CLAUDE_URL}\nPaste code here if prompted > "]], clock: clock)
    code = "x" * 4085 + "#TEST-STATE"
    AuthenticationTestSupport.make_auth_runner(root, sessions: [session], clock: clock) do |runner, _factory, _config|
      expect(runner.login(provider: "claude", on_challenge: ->(_c) {}, input: -> { code }, cancelled: -> { false })["state"]).to eq("connected")
      expect(session.stdin_writes).to eq(["#{code}\n"])
    end
  end
end

test("authentication creates private auth and neutral homes") do
  AiTestSupport.with_tmpdir do |root|
    AuthenticationTestSupport.make_auth_runner(root) do |runner, _factory, config|
      runner.status(provider: "claude")
      [config.auth_dir_for("claude"), config.controlled_home].each do |path|
        expect(File.stat(path).mode & 0o777).to eq(0o700)
      end
    end
  end
end

test("stdin backpressure has a finite deadline") do
  AiTestSupport.with_tmpdir do |root|
    session = Auth::Session.spawn(argv: [RbConfig.ruby, "-e", "sleep 30"], env: {"PATH" => "/usr/bin:/bin"}, cwd: root)
    begin
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { session.write_stdin("x" * 2_000_000, timeout: 0.1) }.to raise_error(IOError)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 2).to eq(true)
    ensure
      session.terminate(grace: 0.1)
    end
  end
end

test("partial pipe creation failure closes already opened descriptors") do
  original = IO.method(:pipe)
  calls = 0
  before = Dir["/dev/fd/*"].size
  begin
    IO.define_singleton_method(:pipe) do |*args|
      calls += 1
      raise Errno::EMFILE if calls == 2
      original.call(*args)
    end
    expect { Auth::Session.spawn(argv: [RbConfig.ruby], env: {}, cwd: Dir.tmpdir) }.to raise_error(Errno::EMFILE)
    expect(Dir["/dev/fd/*"].size).to eq(before)
  ensure
    IO.define_singleton_method(:pipe, original)
  end
end

test("successful parent exit cannot leave a TERM-ignoring auth grandchild") do
  AiTestSupport.with_tmpdir do |root|
    marker = File.join(root, "unexpected-descendant-output")
    parent = File.join(root, "parent.rb")
    File.write(parent, <<~CHILD)
      read_end, write_end = IO.pipe
      fork do
        read_end.close
        trap("TERM") {}
        write_end.write("R")
        write_end.close
        sleep 1.5
        File.write(#{marker.dump}, "alive")
      end
      write_end.close
      read_end.read(1)
      exit 0
    CHILD
    bin = AiTestSupport.make_bin(root, %w[claude])
    config = AiTestSupport.make_config(root, bin: bin, kill_grace_seconds: 0.1)
    factory = FakeSessionFactory.new do |spawn|
      Auth::Session.spawn(argv: [RbConfig.ruby, parent], env: spawn[:env], cwd: spawn[:cwd])
    end
    process = FakeProcessRunner.new([FakeProcessRunner.ok(stdout: JSON.generate({loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty"}))])
    AiTestSupport.with_env("PATH" => bin) do
      runner = Auth::Runner.new(config: config, session_factory: factory, process_runner: process)
      result = runner.login(provider: "claude", timeout: 5, on_challenge: ->(_c) {}, input: -> { nil }, cancelled: -> { false })
      expect(result["state"]).to eq("connected")
      sleep 1.7
      expect(File.exist?(marker)).to eq(false)
    ensure
      factory.spawns.each { |spawn| spawn[:session]&.terminate(grace: 0.1) }
    end
  end
end
