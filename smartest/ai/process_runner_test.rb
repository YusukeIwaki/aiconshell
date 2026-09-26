# frozen_string_literal: true

require_relative "ai_test_helper"

Ai = Aiconshell::Ai unless defined?(Ai)

require "rbconfig"

def real_runner_call(script, argv_extra: [], env: {}, stdin_data: nil, timeout: 10, max_output_bytes: 1_000_000, cwd: nil, kill_grace_seconds: 1)
  AiTestSupport.with_tmpdir do |root|
    cwd ||= root
    result = Ai::ProcessRunner.new.call(
      argv: [RbConfig.ruby, "-e", script, *argv_extra],
      env: { "PATH" => "/usr/bin:/bin" }.merge(env),
      cwd: cwd,
      stdin_data: stdin_data,
      timeout: timeout,
      max_output_bytes: max_output_bytes,
      kill_grace_seconds: kill_grace_seconds
    )
    yield result, root
  end
end

test("process runner captures stdout, stderr and exit status") do
  real_runner_call('STDOUT.puts "out"; STDERR.puts "err"; exit 3') do |result, _root|
    expect(result.stdout).to eq("out\n")
    expect(result.stderr).to eq("err\n")
    expect(result.exit_status).to eq(3)
    expect(result.timed_out?).to eq(false)
    expect(result.success?).to eq(false)
  end
end

test("process runner pipes stdin data to the child") do
  real_runner_call("STDOUT.write STDIN.read.upcase", stdin_data: "hello") do |result, _root|
    expect(result.stdout).to eq("HELLO")
    expect(result.exit_status).to eq(0)
    expect(result.success?).to eq(true)
  end
end

test("process runner honors cwd and the given env only") do
  AiTestSupport.with_env("DATABASE_URL" => "postgres://host-secret/db") do
    real_runner_call('puts Dir.pwd; puts ENV["DATABASE_URL"].inspect; puts ENV["MARKER"].inspect',
      env: { "MARKER" => "present" }) do |result, root|
      lines = result.stdout.lines.map(&:strip)
      expect(lines[0]).to eq(File.realpath(root))
      expect(lines[1]).to eq("nil")
      expect(lines[2]).to eq("\"present\"")
    end
  end
end

test("process runner never interpolates argv through a shell") do
  AiTestSupport.with_tmpdir do |root|
    marker = File.join(root, "pwned")
    literal = "$(touch #{marker}); `touch #{marker}`"
    result = Ai::ProcessRunner.new.call(
      argv: [RbConfig.ruby, "-e", "puts ARGV.first", literal],
      env: { "PATH" => "/usr/bin:/bin" },
      cwd: root, stdin_data: nil, timeout: 10,
      max_output_bytes: 1_000_000, kill_grace_seconds: 1
    )
    expect(result.stdout.strip).to eq(literal)
    expect(File.exist?(marker)).to eq(false)
  end
end

test("process runner times out and kills a sleeping child") do
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  real_runner_call("sleep 30", timeout: 0.5, kill_grace_seconds: 0.2) do |result, _root|
    expect(result.timed_out?).to eq(true)
    expect(result.exit_status).to be_nil
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  expect(elapsed < 25).to eq(true)
end

test("process runner terminates grandchildren with the process group") do
  AiTestSupport.with_tmpdir do |root|
    marker = File.join(root, "grandchild-alive")
    grandchild = File.join(root, "grandchild.rb")
    File.write(grandchild, "sleep 2; File.write(ARGV[0], \"alive\")\n")
    parent = File.join(root, "parent.rb")
    File.write(parent, "spawn(#{RbConfig.ruby.dump}, #{grandchild.dump}, #{marker.dump}); sleep 30\n")
    result = Ai::ProcessRunner.new.call(
      argv: [RbConfig.ruby, parent, marker],
      env: { "PATH" => "/usr/bin:/bin" },
      cwd: root, stdin_data: nil, timeout: 1,
      max_output_bytes: 1_000_000, kill_grace_seconds: 0.2
    )
    expect(result.timed_out?).to eq(true)
    sleep 3 # past the grandchild write delay: the marker must never appear
    expect(File.exist?(marker)).to eq(false)
  end
end

test("process runner bounds stdout and stderr independently") do
  real_runner_call('STDOUT.write "y" * 300_000', max_output_bytes: 100_000) do |result, _root|
    expect(result.stdout_truncated?).to eq(true)
    expect(result.stdout.bytesize).to eq(100_000)
    expect(result.stderr_truncated?).to eq(false)
    expect(result.exit_status).to eq(0)
  end
  real_runner_call('STDERR.write "e" * 300_000; STDOUT.write "ok"', max_output_bytes: 100_000) do |result, _root|
    expect(result.stderr_truncated?).to eq(true)
    expect(result.stderr.bytesize).to eq(100_000)
    expect(result.stdout).to eq("ok")
    expect(result.stdout_truncated?).to eq(false)
  end
end

test("process runner validates its inputs") do
  runner = Ai::ProcessRunner.new
  base = { env: {}, cwd: Dir.tmpdir, stdin_data: nil, timeout: 5, max_output_bytes: 100, kill_grace_seconds: 0.1 }
  expect { runner.call(**base.merge(argv: [])) }.to raise_error(ArgumentError)
  expect { runner.call(**base.merge(argv: ["ls", 42])) }.to raise_error(ArgumentError)
  expect { runner.call(**base.merge(argv: ["echo"], timeout: 0)) }.to raise_error(ArgumentError)
  expect { runner.call(**base.merge(argv: ["echo"], max_output_bytes: 0)) }.to raise_error(ArgumentError)
  expect { runner.call(**base.merge(argv: ["echo"], stdin_data: 42)) }.to raise_error(ArgumentError)
  expect { runner.call(**base.merge(argv: ["echo"], kill_grace_seconds: -1)) }.to raise_error(ArgumentError)
end

test("process runner kills a TERM-ignoring grandchild after the parent exits") do
  AiTestSupport.with_tmpdir do |root|
    pid_file = File.join(root, "grandchild.pid")
    parent = File.join(root, "parent.rb")
    File.write(parent, <<~RUBY)
      $stdout.sync = true
      puts "parent-out"
      fork do
        File.write(#{pid_file.dump}, Process.pid.to_s)
        trap("TERM", "IGNORE")
        sleep 30
      end
      exit 0
    RUBY
    begin
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Ai::ProcessRunner.new.call(
        argv: [RbConfig.ruby, parent],
        env: { "PATH" => "/usr/bin:/bin" },
        cwd: root, stdin_data: "x" * 2_000_000,
        timeout: 10, max_output_bytes: 1_000_000, kill_grace_seconds: 0.3
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(result.timed_out?).to eq(false)
      expect(result.exit_status).to eq(0)
      expect(result.stdout).to eq("parent-out\n")
      expect(elapsed < 8).to eq(true)

      expect(File.exist?(pid_file)).to eq(true)
      grandchild_pid = File.read(pid_file).to_i
      expect(grandchild_pid.positive?).to eq(true)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      dead = loop do
        begin
          Process.kill(0, grandchild_pid)
        rescue Errno::ESRCH
          break true
        end
        break false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.05
      end
      expect(dead).to eq(true)
    ensure
      if File.exist?(pid_file)
        begin
          Process.kill("KILL", File.read(pid_file).to_i)
        rescue SystemCallError, ArgumentError
          nil
        end
      end
    end
  end
end

test("process runner closes all FDs when spawn fails") do
  AiTestSupport.with_tmpdir do |root|
    runner = Ai::ProcessRunner.new
    GC.disable
    begin
      before = Dir["/dev/fd/*"].size
      expect do
        runner.call(
          argv: [RbConfig.ruby, "-e", "exit 0"],
          env: { "PATH" => "/usr/bin:/bin" },
          cwd: File.join(root, "missing-dir"),
          stdin_data: nil, timeout: 5,
          max_output_bytes: 100, kill_grace_seconds: 0.1
        )
      end.to raise_error(SystemCallError)
      expect(Dir["/dev/fd/*"].size).to eq(before)
    ensure
      GC.enable
    end
    # A failed spawn must not wedge later runs.
    real_runner_call('puts "ok"') do |result, _root|
      expect(result.stdout).to eq("ok\n")
    end
  end
end
