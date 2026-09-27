# frozen_string_literal: true

require "json"

module Aiconshell
  module Ai
    module Authentication
      # Muse subscription-status probe over the official MSP wire protocol.
      # The `muse` CLI root offers no auth/login status command, so status is
      # read with the documented experimental `account/read` method: spawn
      # `muse serve` with pipes, exchange newline-delimited JSON-RPC 2.0
      # (`initialize` with the experimental capability, then the
      # `initialized` notification, then parameter-less `account/read`), and
      # terminate the serve child in finite time once answered.
      #
      # Only the `state` member is extracted — labels, avatar URLs and any
      # key material are never read out. `accountLogin` alone counts as
      # connected; `envKey`/`apiKey` are rejected and unknown future states
      # fail safe. Shapes verified against the binary's own offline
      # experimental schema export; see docs/ai-auth-protocol.md.
      module MuseRpc
        SERVE_ARGV = %w[serve --no-session-log --disable-write --disable-shell].freeze
        POLL_INTERVAL = 0.2

        INITIALIZE_PARAMS = {
          "clientInfo" => { "name" => "aiconshell_auth", "version" => "0.1" },
          "capabilities" => { "experimentalApi" => true }
        }.freeze

        module_function

        def check(session_factory:, executable:, env:, cwd:, clock:, timeout:, max_output_bytes:, kill_grace_seconds:, cancelled: -> { false })
          session = session_factory.spawn(
            argv: [executable, *SERVE_ARGV], env: env, cwd: cwd
          )
          run(session, clock: clock, timeout: timeout, max_output_bytes: max_output_bytes, cancelled: cancelled)
        rescue SystemCallError, IOError, ArgumentError
          Result.result("failed", "spawn_failed")
        ensure
          Session.cleanup(session, grace: kill_grace_seconds, clock: clock)
        end

        def run(session, clock:, timeout:, max_output_bytes:, cancelled:)
          send_message(session, { "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => INITIALIZE_PARAMS })
          deadline = clock.call + timeout
          buffer = +""
          bytes = 0
          phase = :initialize
          loop do
            begin
              return Result.result("cancelled", nil) if cancelled.call
            rescue StandardError
              return Result.result("failed", "cancel_check_failed")
            end
            now = clock.call
            return Result.result("failed", "timeout") if now >= deadline

            remaining = deadline - clock.call
            return Result.result("failed", "timeout") if remaining <= 0

            session.wait_output([POLL_INTERVAL, remaining].min)
            out, err = session.read_available
            bytes += out.bytesize + err.bytesize
            return Result.result("failed", "output_capped") if bytes > max_output_bytes

            buffer << out
            outcome = drain_lines(session, buffer, phase)
            return outcome[1] if outcome[0] == :done

            phase = outcome[1]
            next if session.alive?

            final = drain_eof(session, buffer, phase, bytes, max_output_bytes)
            return final if final

            return Result.result("failed", "unexpected_output")
          end
        rescue IOError, SystemCallError
          Result.result("failed", "interrupted")
        end

        # Processes complete lines in the buffer (in place).
        # @return [[:done, Hash]] when the exchange completed,
        #   [[:continue, Symbol]] with the current phase otherwise.
        def drain_lines(session, buffer, phase)
          while (index = buffer.index("\n"))
            line = buffer.slice!(0, index + 1).strip
            next if line.empty?

            message = parse_line(line)
            return [:done, Result.result("failed", "unexpected_output")] if message.nil?

            if phase == :initialize && id_matches?(message["id"], 1)
              return [:done, Result.result("failed", "unexpected_output")] if message.key?("error")
              return [:done, Result.result("failed", "unexpected_output")] unless message["result"].is_a?(Hash)

              send_message(session, { "jsonrpc" => "2.0", "method" => "initialized" })
              send_message(session, { "jsonrpc" => "2.0", "id" => 2, "method" => "account/read" })
              phase = :account
            elsif phase == :account && id_matches?(message["id"], 2)
              return [:done, map_account_result(message)]
            end
            # Notifications and unrelated ids are ignored.
          end
          [:continue, phase]
        end

        # Reads the remaining bytes after the child exited and processes any
        # final lines. Returns a result Hash when the exchange completed, nil
        # when the stream ended without an answer.
        def drain_eof(session, buffer, phase, bytes, max_output_bytes)
          loop do
            out, err = session.read_available
            break if out.empty? && err.empty?

            bytes += out.bytesize + err.bytesize
            return Result.result("failed", "output_capped") if bytes > max_output_bytes

            buffer << out
            outcome = drain_lines(session, buffer, phase)
            return outcome[1] if outcome[0] == :done

            phase = outcome[1]
          end
          nil
        end

        def map_account_result(message)
          return Result.result("failed", "unexpected_output") if message.key?("error")

          payload = message["result"]
          return Result.result("failed", "unexpected_output") unless payload.is_a?(Hash)

          unless [true, false].include?(payload["credentialRequired"])
            return Result.result("failed", "unexpected_output")
          end

          case payload["state"]
          when "accountLogin" then Result.result("connected", nil)
          when "loggedOut" then Result.result("disconnected", nil)
          when "envKey", "apiKey" then Result.result("failed", "auth_rejected")
          else Result.result("failed", "unexpected_output")
          end
        end

        def parse_line(line)
          parsed = JSON.parse(line)
          parsed.is_a?(Hash) ? parsed : nil
        rescue JSON::ParserError
          nil
        end

        def id_matches?(actual, expected)
          actual == expected || actual.to_s == expected.to_s
        end

        def send_message(session, object)
          session.write_stdin("#{JSON.generate(object)}\n")
        end

      end
    end
  end
end
