# frozen_string_literal: true

require "fileutils"
require "json"

module Aiconshell
  module Ai
    module Authentication
      # Runs official CLI login flows and status probes inside the worker.
      #
      # - `status(provider:)` reports the subscription state without any
      #   browser round-trip (Claude/Codex via one-shot CLI status commands,
      #   Muse via the official MSP `account/read` probe).
      # - `login(provider:, timeout:, on_challenge:, input:, cancelled:)`
      #   drives an interactive login: challenges (verification URL plus an
      #   optional user code) go to `on_challenge`, an authorization code is
      #   pulled from `input` for Claude's stdin prompt, and `cancelled` is
      #   polled for cooperative cancellation.
      #
      # Both methods always return a schema-validated string-key Hash
      # (`{"state" => ..., "error_code" => ...}`) and never raise for
      # operational failures: unknown providers, bad inputs, spawn errors,
      # unexpected CLI output and callback failures all map to fixed
      # classifications. Raw stdout/stderr, tokens, secret file contents and
      # exception text never leave this boundary.
      #
      # Children run with an argv array (no shell), `ChildEnv` allowlist env
      # (no DB/integration/API-key variables) and the provider auth dir as
      # dedicated cwd. Authorization codes travel over the stdin pipe only,
      # never argv. Every path terminates the child process group and closes
      # FDs in finite time.
      class Runner
        DEFAULT_LOGIN_TIMEOUT = 900
        STATUS_TIMEOUT = 60
        POLL_INTERVAL = 0.2
        MAX_CODE_CHARS = 256

        DEFAULT_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }.freeze

        CODEX_LOGIN_OVERRIDES = [
          "-c", 'forced_login_method="chatgpt"',
          "-c", 'cli_auth_credentials_store="file"'
        ].freeze

        def initialize(config: Config.default, registry: nil, process_runner: ProcessRunner.new,
          session_factory: Session, clock: DEFAULT_CLOCK)
          unless clock.respond_to?(:call)
            raise ArgumentError, "clock must respond to call"
          end
          unless process_runner.respond_to?(:call)
            raise ArgumentError, "process_runner must respond to call"
          end
          unless session_factory.respond_to?(:spawn)
            raise ArgumentError, "session_factory must respond to spawn"
          end

          @config = config
          @registry = registry || Registry.new(config: config)
          @process_runner = process_runner
          @session_factory = session_factory
          @clock = clock
        end

        # @return [Hash] {"state" => connected|disconnected|unavailable|failed,
        #   "error_code" => nil or fixed classification}
        def status(provider:)
          return Result.result("failed", "invalid_provider") unless valid_provider?(provider)

          executable = @registry.resolve_executable(provider)
          return Result.result("unavailable", nil) if executable.nil?

          dir = prepare_dir(provider)
          return Result.result("failed", "spawn_failed") if dir.nil?

          env = ChildEnv.build(provider: provider, config: @config)
          if provider == "muse"
            return MuseRpc.check(
              session_factory: @session_factory, executable: executable, env: env, cwd: dir,
              clock: @clock, timeout: STATUS_TIMEOUT,
              max_output_bytes: @config.max_output_bytes,
              kill_grace_seconds: @config.kill_grace_seconds
            )
          end

          check_oneshot(provider, executable, env, dir)
        rescue StandardError
          Result.unknown_fallback
        end

        # Drives an interactive subscription login.
        #
        # @param timeout [Numeric] seconds until the attempt expires (900)
        # @param on_challenge [#call] receives each validated challenge Hash
        # @param input [#call] returns nil while empty, the authorization
        #   code String once (Claude only, after the stdin prompt appears)
        # @param cancelled [#call] returns true to abort the attempt
        # @return [Hash] status-shaped; state additionally allows
        #   `cancelled` and `expired`.
        def login(provider:, timeout: DEFAULT_LOGIN_TIMEOUT, on_challenge:, input:, cancelled:)
          timeout = DEFAULT_LOGIN_TIMEOUT if timeout.nil?
          return Result.result("failed", "invalid_provider") unless valid_provider?(provider)
          return Result.result("failed", "invalid_argument") unless valid_timeout?(timeout)
          unless on_challenge.respond_to?(:call) && input.respond_to?(:call) && cancelled.respond_to?(:call)
            return Result.result("failed", "invalid_argument")
          end

          executable = @registry.resolve_executable(provider)
          return Result.result("unavailable", nil) if executable.nil?

          dir = prepare_dir(provider)
          return Result.result("failed", "spawn_failed") if dir.nil?

          early = preflight_cancelled(cancelled)
          return early unless early.nil?

          env = ChildEnv.build(provider: provider, config: @config)
          session = spawn_session(login_argv(provider, executable), env, dir)
          return Result.result("failed", "spawn_failed") if session.nil?

          drive_login(provider, session, timeout,
            on_challenge: on_challenge, input: input, cancelled: cancelled)
        rescue StandardError
          Result.unknown_fallback
        end

        private

        def valid_provider?(provider)
          provider.is_a?(String) && Config::PROVIDERS.include?(provider)
        end

        def valid_timeout?(timeout)
          return false unless timeout.is_a?(Numeric) && timeout.positive?
          return timeout.finite? if timeout.is_a?(Float)

          true
        end

        def prepare_dir(provider)
          dir = @config.auth_dir_for(provider)
          FileUtils.mkdir_p(dir)
          dir
        rescue SystemCallError
          nil
        end

        def login_argv(provider, executable)
          case provider
          when "claude"
            [executable, "auth", "login", "--claudeai"]
          when "codex"
            [executable, "login", "--device-auth", *CODEX_LOGIN_OVERRIDES]
          when "muse"
            [executable, "login"]
          end
        end

        def status_argv(provider, executable)
          case provider
          when "claude"
            [executable, "auth", "status", "--json"]
          when "codex"
            [executable, "login", "status", *CODEX_LOGIN_OVERRIDES]
          end
        end

        def spawn_session(argv, env, cwd)
          @session_factory.spawn(argv: argv, env: env, cwd: cwd)
        rescue SystemCallError, IOError, ArgumentError
          nil
        end

        # Cooperative cancel check before spawning: a pre-cancelled attempt
        # never starts a child. Returns a result Hash when decided, nil to
        # proceed.
        def preflight_cancelled(cancelled)
          cancelled.call ? Result.result("cancelled", nil) : nil
        rescue StandardError
          Result.result("failed", "cancel_check_failed")
        end

        def check_oneshot(provider, executable, env, dir)
          child = @process_runner.call(
            argv: status_argv(provider, executable),
            env: env, cwd: dir, stdin_data: nil,
            timeout: STATUS_TIMEOUT,
            max_output_bytes: @config.max_output_bytes,
            kill_grace_seconds: @config.kill_grace_seconds
          )
          return Result.result("failed", "timeout") if child.timed_out?
          if child.stdout_truncated? || child.stderr_truncated?
            return Result.result("failed", "output_capped")
          end

          if provider == "claude"
            parse_claude_status(child.stdout)
          else
            parse_codex_status("#{child.stdout}\n#{child.stderr}")
          end
        rescue SystemCallError, IOError
          Result.result("failed", "spawn_failed")
        end

        # `claude auth status --json` prints {"loggedIn": bool, ...} (exit 1
        # when logged out). The body is authoritative; only the subscription
        # signal is extracted, never paths or raw text.
        def parse_claude_status(stdout)
          parsed = JSON.parse(stdout.to_s.strip)
          return Result.result("failed", "unexpected_output") unless parsed.is_a?(Hash)

          case parsed["loggedIn"]
          when true
            method = parsed["authMethod"]
            if method.is_a?(String) && method.match?(/api[\s_-]?key|access[\s_-]?token|\bconsole\b/i)
              Result.result("failed", "auth_rejected")
            else
              Result.result("connected", nil)
            end
          when false
            Result.result("disconnected", nil)
          else
            Result.result("failed", "unexpected_output")
          end
        rescue JSON::ParserError
          Result.result("failed", "unexpected_output")
        end

        # `codex login status` prints human text ("Not logged in" with exit 1
        # when logged out). API-key selections are rejected, never connected.
        def parse_codex_status(text)
          if text.match?(/api[\s_-]?key|access[\s_-]?token|--with-api-key|--with-access-token/i) ||
              text.match?(/OPENAI_API_KEY|CODEX_(API_KEY|ACCESS_TOKEN)/)
            Result.result("failed", "auth_rejected")
          elsif text.match?(/not\s+logged\s+in/i) || text.match?(/\blogged\s+out\b/i)
            Result.result("disconnected", nil)
          elsif text.match?(/chatgpt/i) || text.match?(/\blogged\s+in\b/i) || text.match?(/\bsigned\s+in\b/i)
            Result.result("connected", nil)
          else
            Result.result("failed", "unexpected_output")
          end
        end

        def drive_login(provider, session, timeout, on_challenge:, input:, cancelled:)
          scanner = Scanner.new(provider)
          emitted = nil
          code_delivered = false
          deadline = @clock.call + timeout
          loop do
            return abort(session, "expired", nil) if @clock.call >= deadline

            cancel_decision = poll_cancelled(session, cancelled)
            return cancel_decision unless cancel_decision.nil?

            remaining = deadline - @clock.call
            return abort(session, "expired", nil) if remaining <= 0

            begin
              session.wait_output([POLL_INTERVAL, remaining].min)
              out, err = session.read_available
            rescue IOError, SystemCallError
              return abort(session, "failed", "interrupted")
            end

            unless out.empty? && err.empty?
              decision = ingest(provider, session, scanner, out, err,
                on_challenge: on_challenge, emit: true, emitted: emitted)
              return decision[:result] if decision[:done]

              emitted = decision[:emitted]
            end

            unless code_delivered
              delivery = maybe_deliver_code(session, scanner, input)
              return delivery unless delivery.nil? || delivery == :delivered

              code_delivered = true if delivery == :delivered
            end

            next if poll_alive(session)

            return finish_login(provider, session, scanner, emitted, on_challenge: on_challenge)
          end
        ensure
          close_session(session)
        end

        def poll_alive(session)
          session.alive?
        rescue IOError, SystemCallError
          false
        end

        def poll_cancelled(session, cancelled)
          cancelled.call ? abort(session, "cancelled", nil) : nil
        rescue StandardError
          abort(session, "failed", "cancel_check_failed")
        end

        # Feeds fresh output through the scanner and runs the fail-fast
        # checks plus challenge emission.
        # @return [{done: bool, result: Hash/nil, emitted: Hash/nil}]
        def ingest(provider, session, scanner, out, err, on_challenge:, emit:, emitted:)
          scanner.feed(out)
          scanner.feed(err)
          return finish_decision(abort(session, "failed", "output_capped")) if scanner.bytes > @config.max_output_bytes
          return finish_decision(abort(session, "failed", "challenge_rejected")) if scanner.foreign_url?
          return finish_decision(abort(session, "failed", "auth_rejected")) if scanner.api_key_hit?

          challenge = scanner.challenge
          return continue_decision(emitted) if challenge.nil? || !emit

          result, emitted = maybe_emit(provider, session, challenge, emitted, on_challenge)
          return finish_decision(result) unless result.nil?

          continue_decision(emitted)
        end

        def finish_decision(result)
          { done: true, result: result, emitted: nil }
        end

        def continue_decision(emitted)
          { done: false, result: nil, emitted: emitted }
        end

        # Emits the challenge unless it is unchanged since the last emission.
        # @return [(Hash/nil, Hash/nil)] [terminal result, current emission]
        def maybe_emit(provider, session, challenge, emitted, on_challenge)
          return [nil, emitted] if challenge == emitted

          built = Result.challenge(
            provider: provider,
            verification_uri: challenge["verification_uri"],
            user_code: challenge["user_code"],
            input_required: challenge["input_required"]
          )
          return [abort(session, "failed", "challenge_rejected"), emitted] if built.nil?

          begin
            on_challenge.call(built)
          rescue StandardError
            return [abort(session, "failed", "callback_failed"), emitted]
          end
          [nil, challenge]
        end

        # Pulls the authorization code for Claude's stdin prompt. Returns nil
        # to keep waiting, :delivered after writing, or a result Hash to end.
        def maybe_deliver_code(session, scanner, input)
          return nil unless scanner.input_required?

          code = begin
            input.call
          rescue StandardError
            return abort(session, "failed", "input_failed")
          end
          return nil if code.nil?

          cleaned = clean_code(code)
          return abort(session, "failed", "input_failed") if cleaned.nil?

          begin
            session.write_stdin("#{cleaned}\n")
            session.close_stdin
          rescue IOError, SystemCallError
            return abort(session, "failed", "interrupted")
          end
          :delivered
        end

        def clean_code(code)
          return nil unless code.is_a?(String)

          cleaned = code.strip
          return nil if cleaned.empty? || cleaned.length > MAX_CODE_CHARS
          return nil if cleaned.match?(/[\x00-\x1F\x7F]/)

          cleaned
        end

        def finish_login(provider, session, scanner, emitted, on_challenge:)
          # Drain buffered pipe output left at exit, then finalize.
          loop do
            begin
              out, err = session.read_available
            rescue IOError, SystemCallError
              break
            end
            break if out.empty? && err.empty?

            decision = ingest(provider, session, scanner, out, err,
              on_challenge: on_challenge, emit: false, emitted: emitted)
            return decision[:result] if decision[:done]
          end
          scanner.finish
          return abort(session, "failed", "output_capped") if scanner.bytes > @config.max_output_bytes
          return abort(session, "failed", "challenge_rejected") if scanner.foreign_url?
          return abort(session, "failed", "auth_rejected") if scanner.api_key_hit?

          status = exit_status_of(session)
          if status == 0
            Result.result("connected", nil)
          elsif scanner.exit_hint == :expired
            Result.result("expired", nil)
          elsif scanner.exit_hint == :auth_failed
            Result.result("failed", "auth_rejected")
          else
            Result.result("failed", "unexpected_output")
          end
        end

        def exit_status_of(session)
          session.exit_status
        rescue IOError, SystemCallError
          nil
        end

        # Terminates the child group, closes FDs, and builds the result.
        # Termination is unconditional: even when the parent already exited,
        # orphaned grandchildren must not outlive the attempt.
        def abort(session, state, error_code)
          kill_session(session)
          Result.result(state, error_code)
        end

        def kill_session(session)
          return if session.nil?

          begin
            session.terminate(grace: @config.kill_grace_seconds)
          rescue StandardError
            nil
          end
          begin
            session.close
          rescue StandardError
            nil
          end
        end

        def close_session(session)
          return if session.nil?

          begin
            session.terminate(grace: @config.kill_grace_seconds) if session.alive?
          rescue StandardError
            nil
          end
          begin
            session.close
          rescue StandardError
            nil
          end
        end

      end
    end
  end
end
