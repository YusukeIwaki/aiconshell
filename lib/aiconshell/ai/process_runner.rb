# frozen_string_literal: true

module Aiconshell
  module Ai
    # Immutable value returned by process runners.
    Result = Struct.new(
      :stdout, :stderr, :exit_status, :timed_out,
      :stdout_truncated, :stderr_truncated,
      keyword_init: true
    ) do
      def timed_out?
        !!timed_out
      end

      def stdout_truncated?
        !!stdout_truncated
      end

      def stderr_truncated?
        !!stderr_truncated
      end

      def success?
        !timed_out? && exit_status == 0
      end
    end

    # Real subprocess runner. Spawns the provider CLI with an argv array (no
    # shell), a controlled environment and working directory, a monotonic
    # timeout, and bounded stdout/stderr captures. The child runs in its own
    # process group; on timeout the whole group receives TERM, then KILL after
    # a grace period, so grandchildren cannot outlive the run.
    class ProcessRunner
      READ_CHUNK = 65_536
      WAIT_POLL_INTERVAL = 0.02

      def call(argv:, env:, cwd:, stdin_data: nil, timeout:, max_output_bytes:, kill_grace_seconds: 5)
        validate!(argv, stdin_data, timeout, max_output_bytes)

        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, stderr_write = IO.pipe
        pid = nil
        begin
          pid = Process.spawn(
            env, argv[0], *argv[1..],
            chdir: cwd, pgroup: true,
            unsetenv_others: true,
            in: stdin_read, out: stdout_write, err: stderr_write,
            close_others: true
          )
        ensure
          stdin_read.close unless stdin_read.closed?
          stdout_write.close unless stdout_write.closed?
          stderr_write.close unless stderr_write.closed?
        end

        writers = [start_stdin_writer(stdin_write, stdin_data)]
        collectors = [
          start_collector(stdout_read, max_output_bytes),
          start_collector(stderr_read, max_output_bytes)
        ]

        status, timed_out = wait_with_timeout(pid, timeout, kill_grace_seconds)

        writers.each(&:join)
        outputs = collectors.map(&:value)

        Result.new(
          stdout: outputs[0].content,
          stderr: outputs[1].content,
          exit_status: status&.exitstatus,
          timed_out: timed_out,
          stdout_truncated: outputs[0].truncated,
          stderr_truncated: outputs[1].truncated
        )
      end

      private

      Collector = Struct.new(:content, :truncated, keyword_init: true)

      def validate!(argv, stdin_data, timeout, max_output_bytes)
        unless argv.is_a?(Array) && !argv.empty? && argv.all?(String)
          raise ArgumentError, "argv must be a non-empty Array of Strings"
        end
        if !stdin_data.nil? && !stdin_data.is_a?(String)
          raise ArgumentError, "stdin_data must be a String or nil"
        end
        raise ArgumentError, "timeout must be positive" unless timeout.is_a?(Numeric) && timeout.positive?
        unless max_output_bytes.is_a?(Integer) && max_output_bytes.positive?
          raise ArgumentError, "max_output_bytes must be a positive Integer"
        end
      end

      def start_stdin_writer(io, data)
        Thread.new do
          begin
            io.write(data) if data && !data.empty?
          rescue IOError, Errno::EPIPE
            nil
          ensure
            io.close unless io.closed?
          end
        end
      end

      def start_collector(io, cap)
        Thread.new do
          buffer = +""
          truncated = false
          begin
            loop do
              chunk = io.readpartial(READ_CHUNK)
              if buffer.bytesize < cap
                room = cap - buffer.bytesize
                buffer << chunk.byteslice(0, room)
                truncated = true if chunk.bytesize > room
              else
                truncated = true
              end
            rescue EOFError
              break
            end
          rescue IOError
            nil
          ensure
            io.close unless io.closed?
          end
          Collector.new(content: scrub(buffer), truncated: truncated)
        end
      end

      def wait_with_timeout(pid, timeout, grace)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          _pid, status = Process.waitpid2(pid, Process::WNOHANG)
          return [status, false] if status

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            kill_group(pid, grace)
            return [reap(pid), true]
          end

          sleep(WAIT_POLL_INTERVAL)
        end
      rescue Errno::ECHILD
        [nil, false]
      end

      def kill_group(pid, grace)
        signal_group(pid, "TERM")
        grace_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace
        loop do
          begin
            _pid, status = Process.waitpid2(pid, Process::WNOHANG)
            return status if status
          rescue Errno::ECHILD
            return nil
          end
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= grace_deadline

          sleep(WAIT_POLL_INTERVAL)
        end
        signal_group(pid, "KILL")
        reap(pid)
      end

      def signal_group(pid, signal)
        Process.kill("-#{signal}", pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def reap(pid)
        _pid, status = Process.waitpid2(pid)
        status
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end

      def scrub(string)
        string = string.dup.force_encoding(Encoding::UTF_8)
        string.scrub
      end
    end
  end
end
