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
    # process group.
    #
    # End-to-end bound: the parent is waited on for at most `timeout`; group
    # cleanup (TERM, wait, KILL, confirm) is bounded by `kill_grace_seconds`
    # per phase; I/O threads are never joined unbounded. Cleanup runs even
    # when the parent exits promptly, because grandchildren that ignore TERM
    # or hold pipes open would otherwise outlive the run or wedge the
    # collectors. Parent-side FDs are closed on every path, including spawn
    # failure.
    class ProcessRunner
      READ_CHUNK = 65_536
      WAIT_POLL_INTERVAL = 0.02
      # Bounded drain for I/O threads before escalating to signals / FD
      # close, and again after. Keeps the normal path fast (EOF arrives
      # immediately) while capping the stuck-pipe path.
      IO_DRAIN_SECONDS = 2

      def call(argv:, env:, cwd:, stdin_data: nil, timeout:, max_output_bytes:, kill_grace_seconds: 5)
        validate!(argv, stdin_data, timeout, max_output_bytes, kill_grace_seconds)

        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, stderr_write = IO.pipe
        parent_fds = [stdin_write, stdout_read, stderr_read]
        pid = spawn_child!(
          argv, env, cwd,
          stdin_read, stdin_write, stdout_read, stdout_write, stderr_read, stderr_write
        )

        writer = start_stdin_writer(stdin_write, stdin_data)
        collectors = [
          start_collector(stdout_read, max_output_bytes),
          start_collector(stderr_read, max_output_bytes)
        ]
        threads = [writer, *collectors]
        begin
          parent_deadline = monotonic + timeout
          status, timed_out = wait_for_parent(pid, parent_deadline)

          if timed_out
            status = ensure_group_dead(pid, kill_grace_seconds)
          else
            # Parent exited (status already reaped): give I/O a bounded
            # drain first so in-flight output is preserved, then still
            # force the group down — a TERM-ignoring grandchild holding
            # pipes must not wedge us. The reaped status is kept as-is.
            unless join_all(threads, monotonic + IO_DRAIN_SECONDS)
              ensure_group_dead(pid, kill_grace_seconds)
            end
            ensure_group_dead(pid, kill_grace_seconds) if group_alive?(pid)
          end

          outputs = finish_io!(threads, parent_fds)

          Result.new(
            stdout: outputs[0].content,
            stderr: outputs[1].content,
            exit_status: status&.exitstatus,
            timed_out: timed_out,
            stdout_truncated: outputs[0].truncated,
            stderr_truncated: outputs[1].truncated
          )
        ensure
          parent_fds.each { |io| close_quietly(io) }
          threads.each { |thread| thread.kill if thread.alive? }
        end
      end

      private

      Collector = Struct.new(:content, :truncated, keyword_init: true)

      def validate!(argv, stdin_data, timeout, max_output_bytes, kill_grace_seconds)
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
        unless kill_grace_seconds.is_a?(Numeric) && kill_grace_seconds >= 0
          raise ArgumentError, "kill_grace_seconds must be a non-negative number"
        end
      end

      # Spawns the child in its own process group. On success the child-side
      # pipe ends are closed in the parent; on spawn failure all six ends are
      # closed before the error propagates so no FD leaks.
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

      def start_stdin_writer(io, data)
        Thread.new do
          begin
            io.write(data) if data && !data.empty?
          rescue IOError, Errno::EPIPE
            nil
          ensure
            close_quietly(io)
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
            close_quietly(io)
          end
          Collector.new(content: scrub(buffer), truncated: truncated)
        end
      end

      def wait_for_parent(pid, deadline)
        loop do
          _pid, status = Process.waitpid2(pid, Process::WNOHANG)
          return [status, false] if status
          return [nil, true] if monotonic >= deadline

          sleep(WAIT_POLL_INTERVAL)
        end
      rescue Errno::ECHILD
        [nil, false]
      end

      # TERM the whole group, wait for it to drain (reaping the parent along
      # the way), then KILL and confirm — bounded by `grace` per phase.
      # Runs even after the parent exits: group signals are pgid-based, so
      # orphaned grandchildren are still reached. Returns the parent status
      # when it could be reaped, nil otherwise.
      def ensure_group_dead(pid, grace)
        status = try_reap(pid)
        return status if group_empty?(pid)

        signal_group(pid, "TERM")
        term_deadline = monotonic + grace
        until monotonic >= term_deadline
          status ||= try_reap(pid)
          break if group_empty?(pid)

          sleep(WAIT_POLL_INTERVAL)
        end
        status ||= try_reap(pid)
        return status if group_empty?(pid)

        signal_group(pid, "KILL")
        kill_deadline = monotonic + grace
        until monotonic >= kill_deadline
          status ||= try_reap(pid)
          break if group_empty?(pid)

          sleep(WAIT_POLL_INTERVAL)
        end
        status ||= try_reap(pid)
        status
      end

      def group_alive?(pid)
        !group_empty?(pid)
      end

      def group_empty?(pid)
        Process.kill(0, -pid)
        false
      rescue Errno::ESRCH
        true
      rescue Errno::EPERM
        false
      end

      def try_reap(pid)
        _pid, status = Process.waitpid2(pid, Process::WNOHANG)
        status
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end

      def signal_group(pid, signal)
        Process.kill("-#{signal}", pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      # Bounded join of every I/O thread. Returns true when all finished
      # before the deadline.
      def join_all(threads, deadline)
        loop do
          alive = threads.select(&:alive?)
          return true if alive.empty?
          return false if monotonic >= deadline

          alive.first.join([deadline - monotonic, WAIT_POLL_INTERVAL].max)
        end
      end

      # Final bounded I/O settle: join, then close our pipe ends to force
      # EOF/EPIPE in stuck threads, join again, and kill stragglers as a
      # last resort (their output is marked truncated).
      def finish_io!(threads, parent_fds)
        return thread_results(threads) if join_all(threads, monotonic + IO_DRAIN_SECONDS)

        parent_fds.each { |io| close_quietly(io) }
        join_all(threads, monotonic + IO_DRAIN_SECONDS)
        threads.each { |thread| thread.kill if thread.alive? }
        join_all(threads, monotonic + IO_DRAIN_SECONDS)
        thread_results(threads)
      end

      def thread_results(threads)
        _writer, stdout_collector, stderr_collector = threads
        [collector_value(stdout_collector), collector_value(stderr_collector)]
      end

      def collector_value(thread)
        return Collector.new(content: "", truncated: true) if thread.alive?

        value = thread.value
        value.is_a?(Collector) ? value : Collector.new(content: "", truncated: true)
      rescue StandardError
        Collector.new(content: "", truncated: true)
      end

      def close_quietly(io)
        io.close unless io.closed?
      rescue IOError
        nil
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def scrub(string)
        string = string.dup.force_encoding(Encoding::UTF_8)
        string.scrub
      end
    end
  end
end
