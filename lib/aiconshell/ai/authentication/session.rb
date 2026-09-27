# frozen_string_literal: true

module Aiconshell
  module Ai
    module Authentication
      # Interactive subprocess session for login flows and the Muse status
      # probe. Unlike the one-shot ProcessRunner, this keeps stdin open so an
      # authorization code (or JSON-RPC requests) can be written while output
      # is read incrementally.
      #
      # Spawning mirrors the established boundary: argv array (no shell),
      # explicit allowlist env with `unsetenv_others`, dedicated cwd, own
      # process group. `terminate` kills the whole group (TERM, wait, KILL,
      # confirm — bounded by `grace`) and closes every parent FD; `close`
      # only releases FDs. The group-cleanup discipline intentionally
      # duplicates ProcessRunner's (that file belongs to another lane).
      class Session
        READ_CHUNK = 65_536
        WAIT_POLL_INTERVAL = 0.02

        def self.spawn(argv:, env:, cwd:)
          new(argv: argv, env: env, cwd: cwd)
        end

        def initialize(argv:, env:, cwd:)
          validate!(argv, env, cwd)
          opened = []
          stdin_read, stdin_write = IO.pipe.tap { |pair| opened.concat(pair) }
          stdout_read, stdout_write = IO.pipe.tap { |pair| opened.concat(pair) }
          stderr_read, stderr_write = IO.pipe.tap { |pair| opened.concat(pair) }
          @pid = spawn_child!(
            argv, env, cwd,
            stdin_read, stdin_write, stdout_read, stdout_write, stderr_read, stderr_write
          )
          @stdin_write = stdin_write
          @stdout_read = stdout_read
          @stderr_read = stderr_read
          @stdout_eof = false
          @stderr_eof = false
          @reaped = false
          @status = nil
        rescue Exception
          opened&.each { |io| close_quietly(io) }
          raise
        end

        # Close stdin first so official servers can persist and exit normally.
        # Always clean the process group, even if its parent has already exited.
        def self.cleanup(session, grace:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          return unless session

          begin
            session.close_stdin
            deadline = clock.call + [grace, 0.25].min
            while session.alive? && clock.call < deadline
              session.wait_output(0.02)
              session.read_available
            end
          rescue StandardError
            nil
          ensure
            begin
              session.terminate(grace: grace)
            ensure
              session.close
            end
          end
        rescue StandardError
          nil
        end

        # True while the child is still running. Reaps on exit.
        def alive?
          return false if @reaped

          _pid, status = Process.waitpid2(@pid, Process::WNOHANG)
          if status
            @reaped = true
            @status = status
            false
          else
            true
          end
        rescue Errno::ECHILD
          @reaped = true
          false
        end

        # Integer exit status once the child has exited, nil while running.
        def exit_status
          return nil if alive?

          @status&.exitstatus
        end

        # Blocks up to `timeout` seconds until stdout/stderr is readable or
        # the child exits. Returns true on such progress, false on timeout.
        def wait_output(timeout)
          deadline = monotonic + timeout
          loop do
            return true unless alive?

            fds = open_read_fds
            remaining = deadline - monotonic
            return false if remaining <= 0

            if fds.empty?
              sleep([remaining, WAIT_POLL_INTERVAL].min)
              next
            end

            readable, = IO.select(fds, nil, nil, remaining)
            return true if readable && !readable.empty?

            return true unless alive?

            return false
          end
        rescue IOError
          !alive?
        end

        # Reads whatever is immediately available without blocking.
        # @return [Array<String>] [stdout_chunk, stderr_chunk]
        def read_available
          fds = open_read_fds
          return ["", ""] if fds.empty?

          readable, = IO.select(fds, nil, nil, 0)
          readable ||= []
          out = readable.include?(@stdout_read) ? drain(@stdout_read, :stdout) : ""
          err = readable.include?(@stderr_read) ? drain(@stderr_read, :stderr) : ""
          [out, err]
        rescue IOError
          ["", ""]
        end

        # Writes to child stdin. Raises IOError/Errno::EPIPE when the child
        # has closed stdin; the caller maps that to a fixed classification.
        def write_stdin(data, timeout: 2)
          raise IOError, "stdin is closed" if @stdin_write.nil? || @stdin_write.closed?

          deadline = monotonic + timeout
          bytes = data.b
          offset = 0
          while offset < bytes.bytesize
            remaining = deadline - monotonic
            raise IOError, "stdin write timed out" if remaining <= 0

            count = @stdin_write.write_nonblock(bytes.byteslice(offset..), exception: false)
            if count == :wait_writable
              IO.select(nil, [@stdin_write], nil, [remaining, 0.05].min)
            else
              offset += count
            end
          end
          offset
        end

        def close_stdin
          close_quietly(@stdin_write)
        end

        # Kills the whole process group when anything is still alive, reaps
        # the child, and closes every parent FD. Returns the exit status.
        def terminate(grace:)
          status = try_reap
          unless group_empty?
            signal_group("TERM")
            term_deadline = monotonic + grace
            until monotonic >= term_deadline
              status ||= try_reap
              break if group_empty?

              sleep(WAIT_POLL_INTERVAL)
            end
            status ||= try_reap
            unless group_empty?
              signal_group("KILL")
              kill_deadline = monotonic + grace
              until monotonic >= kill_deadline
                status ||= try_reap
                break if group_empty?

                sleep(WAIT_POLL_INTERVAL)
              end
              status ||= try_reap
            end
          end
          close
          status&.exitstatus
        end

        # Closes every parent-side FD. Idempotent; never kills.
        def close
          close_quietly(@stdin_write)
          close_quietly(@stdout_read)
          close_quietly(@stderr_read)
        end

        private

        def validate!(argv, env, cwd)
          unless argv.is_a?(Array) && !argv.empty? && argv.all?(String)
            raise ArgumentError, "argv must be a non-empty Array of Strings"
          end
          unless env.is_a?(Hash) && env.keys.all?(String) && env.values.all?(String)
            raise ArgumentError, "env must be a Hash of String to String"
          end
          raise ArgumentError, "cwd must be a String" unless cwd.is_a?(String)
        end

        def spawn_child!(argv, env, cwd, stdin_read, stdin_write, stdout_read, stdout_write, stderr_read, stderr_write)
          Process.spawn(
            env, argv[0], *argv[1..],
            chdir: cwd, pgroup: true,
            unsetenv_others: true,
            in: stdin_read, out: stdout_write, err: stderr_write,
            close_others: true
          ).tap do
            close_quietly(stdin_read)
            close_quietly(stdout_write)
            close_quietly(stderr_write)
          end
        rescue StandardError
          [stdin_read, stdin_write, stdout_read, stdout_write, stderr_read, stderr_write].each do |io|
            close_quietly(io)
          end
          raise
        end

        def open_read_fds
          fds = []
          fds << @stdout_read if !@stdout_eof && !@stdout_read.closed?
          fds << @stderr_read if !@stderr_eof && !@stderr_read.closed?
          fds
        end

        def drain(io, which)
          io.readpartial(READ_CHUNK)
        rescue EOFError, IOError
          mark_eof(which)
          ""
        end

        def mark_eof(which)
          if which == :stdout
            @stdout_eof = true
          else
            @stderr_eof = true
          end
        end

        def try_reap
          return @status if @reaped

          _pid, status = Process.waitpid2(@pid, Process::WNOHANG)
          if status
            @reaped = true
            @status = status
          end
          @status
        rescue Errno::ECHILD, Errno::ESRCH
          @reaped = true
          @status
        end

        def group_empty?
          Process.kill(0, -@pid)
          false
        rescue Errno::ESRCH
          true
        rescue Errno::EPERM
          false
        end

        def signal_group(signal)
          Process.kill("-#{signal}", @pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end

        def close_quietly(io)
          return if io.nil?

          io.close unless io.closed?
        rescue IOError
          nil
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
