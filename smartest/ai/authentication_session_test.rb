# frozen_string_literal: true

require_relative "authentication_support"

require "rbconfig"

Ai = Aiconshell::Ai unless defined?(Ai)
Auth = Aiconshell::Ai::Authentication unless defined?(Auth)

def auth_session_env(root, provider)
  bin = AiTestSupport.make_bin(root, %w[claude codex muse])
  config = AiTestSupport.make_config(root, bin: bin)
  [Ai::ChildEnv.build(provider: provider, config: config), config.auth_dir_for(provider)]
end

test("auth session relays a stdin code and reads incremental output") do
  AiTestSupport.with_tmpdir do |root|
    env, cwd = auth_session_env(root, "claude")
    FileUtils.mkdir_p(cwd)
    session = Auth::Session.spawn(
      argv: [RbConfig.ruby, "-e", 'STDOUT.sync = true; puts "prompt"; line = STDIN.gets; puts "got #{line.to_s.strip.length} bytes"'],
      env: env, cwd: cwd
    )
    begin
      expect(session.alive?).to eq(true)
      expect(session.wait_output(5)).to eq(true)
      out, _err = session.read_available
      expect(out).to eq("prompt\n")
      session.write_stdin("UNIT-TEST-PASTE-0\n")
      session.close_stdin
      expect(session.wait_output(5)).to eq(true)
      rest = ""
      loop do
        chunk, _ = session.read_available
        rest += chunk
        break if !session.alive? && chunk.empty?
        break if rest.include?("bytes")
      end
      expect(rest).to eq("got 17 bytes\n")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep 0.05 while session.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      expect(session.alive?).to eq(false)
      expect(session.exit_status).to eq(0)
    ensure
      session.terminate(grace: 1)
    end
  end
end

test("auth session confines env, cwd and argv") do
  AiTestSupport.with_tmpdir do |root|
    AiTestSupport.with_env("DATABASE_URL" => "postgres://secret/db", "OPENAI_API_KEY" => "sk-secret") do
      env, cwd = auth_session_env(root, "codex")
      FileUtils.mkdir_p(cwd)
      marker = File.join(root, "pwned")
      literal = "$(touch #{marker}); `touch #{marker}`"
      session = Auth::Session.spawn(
        argv: [RbConfig.ruby, "-e", 'puts Dir.pwd; puts ENV.keys.sort.join(","); puts ARGV.first', literal],
        env: env, cwd: cwd
      )
      begin
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        sleep 0.05 while session.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        output = +""
        loop do
          chunk, _ = session.read_available
          break if chunk.empty?

          output += chunk
        end
        lines = output.lines.map(&:strip)
        expect(lines[0]).to eq(File.realpath(cwd))
        # Exact-set comparison is impossible: macOS injects
        # __CF_USER_TEXT_ENCODING into every child. Assert the allowlist keys
        # plus absence of application secrets instead.
        keys = lines[1].split(",")
        %w[CODEX_HOME HOME LANG LC_ALL PATH TMPDIR].each do |key|
          expect(keys.include?(key)).to eq(true)
        end
        %w[DATABASE_URL OPENAI_API_KEY META_API_KEY ANTHROPIC_API_KEY].each do |key|
          expect(keys.include?(key)).to eq(false)
        end
        expect(lines[2]).to eq(literal)
        expect(File.exist?(marker)).to eq(false)
        expect(session.exit_status).to eq(0)
      ensure
        session.terminate(grace: 1)
      end
    end
  end
end

test("auth session wait reports timeouts and exits") do
  AiTestSupport.with_tmpdir do |root|
    env, cwd = auth_session_env(root, "muse")
    FileUtils.mkdir_p(cwd)
    session = Auth::Session.spawn(
      argv: [RbConfig.ruby, "-e", "sleep 30"],
      env: env, cwd: cwd
    )
    begin
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(session.wait_output(0.2)).to eq(false)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 10).to eq(true)
      expect(session.alive?).to eq(true)
      session.terminate(grace: 1)
      expect(session.alive?).to eq(false)
    ensure
      session.terminate(grace: 1)
    end

    quick = Auth::Session.spawn(
      argv: [RbConfig.ruby, "-e", "exit 3"],
      env: env, cwd: cwd
    )
    begin
      expect(quick.wait_output(5)).to eq(true)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep 0.05 while quick.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      expect(quick.exit_status).to eq(3)
    ensure
      quick.terminate(grace: 1)
    end
  end
end

test("auth session terminates the process group including grandchildren") do
  AiTestSupport.with_tmpdir do |root|
    env, cwd = auth_session_env(root, "codex")
    FileUtils.mkdir_p(cwd)
    marker = File.join(root, "grandchild-alive")
    grandchild = File.join(root, "grandchild.rb")
    File.write(grandchild, "sleep 5; File.write(ARGV[0], \"alive\")\n")
    parent = File.join(root, "parent.rb")
    File.write(parent, "spawn(#{RbConfig.ruby.dump}, #{grandchild.dump}, #{marker.dump}); sleep 30\n")
    session = Auth::Session.spawn(argv: [RbConfig.ruby, parent, marker], env: env, cwd: cwd)
    begin
      sleep 0.5 # let the grandchild spawn
      session.terminate(grace: 0.5)
      expect(session.alive?).to eq(false)
      sleep 6 # past the grandchild write delay: the marker must never appear
      expect(File.exist?(marker)).to eq(false)
    ensure
      session.terminate(grace: 0.5)
    end
  end
end

test("auth session closes all fds when spawn fails") do
  AiTestSupport.with_tmpdir do |root|
    env, _cwd = auth_session_env(root, "claude")
    GC.disable
    begin
      before = Dir["/dev/fd/*"].size
      expect do
        Auth::Session.spawn(
          argv: [RbConfig.ruby, "-e", "exit 0"],
          env: env, cwd: File.join(root, "missing-dir")
        )
      end.to raise_error(SystemCallError)
      expect(Dir["/dev/fd/*"].size).to eq(before)
    ensure
      GC.enable
    end
  end
end

test("auth session validates spawn arguments") do
  expect { Auth::Session.spawn(argv: [], env: {}, cwd: Dir.tmpdir) }.to raise_error(ArgumentError)
  expect { Auth::Session.spawn(argv: ["x", 1], env: {}, cwd: Dir.tmpdir) }.to raise_error(ArgumentError)
  expect { Auth::Session.spawn(argv: ["x"], env: { "A" => 1 }, cwd: Dir.tmpdir) }.to raise_error(ArgumentError)
  expect { Auth::Session.spawn(argv: ["x"], env: {}, cwd: nil) }.to raise_error(ArgumentError)
end

test("auth session terminate and close are idempotent") do
  AiTestSupport.with_tmpdir do |root|
    env, cwd = auth_session_env(root, "muse")
    FileUtils.mkdir_p(cwd)
    session = Auth::Session.spawn(argv: [RbConfig.ruby, "-e", "exit 0"], env: env, cwd: cwd)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.05 while session.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    expect(session.terminate(grace: 1)).to eq(0)
    expect(session.terminate(grace: 1)).to eq(0)
    session.close
    session.close
    expect(session.exit_status).to eq(0)
  end
end
