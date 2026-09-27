# frozen_string_literal: true

require "json"

module Aiconshell
  module Ai
    module Authentication
      # Official app-server stdio protocol. Only device-code challenges and
      # subscription state cross this boundary; the CLI owns token exchange.
      class CodexRpc
        ARGV = ["-c", 'forced_login_method="chatgpt"',
                "-c", 'cli_auth_credentials_store="file"',
                "app-server", "--listen", "stdio://"].freeze
        Failure = Class.new(StandardError)

        def initialize(session_factory:, executable:, env:, cwd:, clock:, timeout:,
                       max_output_bytes:, kill_grace_seconds:, on_challenge: nil,
                       cancelled: -> { false })
          @factory, @argv, @env, @cwd = session_factory, [executable, *ARGV], env, cwd
          @clock, @timeout, @limit, @grace = clock, timeout, max_output_bytes, kill_grace_seconds
          @on_challenge, @cancelled = on_challenge, cancelled
          @buffer, @bytes, @early_completions = +"", 0, {}
        end

        def call
          @deadline = @clock.call + @timeout
          @session = @factory.spawn(argv: @argv, env: @env, cwd: @cwd)
          @phase = :initialize
          send_message(id: 1, method: "initialize", params: {
            clientInfo: { name: "aiconshell_auth", version: "0.1" },
            capabilities: { experimentalApi: false }
          })
          loop do
            stop = stop_result
            return stop if stop

            @session.wait_output([0.2, @deadline - @clock.call].min)
            read_messages.each do |message|
              stop = stop_result
              return stop if stop

              outcome = accept(message)
              return outcome if outcome
            end
            next if @session.alive?

            # Drain remaining complete frames after the server exits.
            read_messages.each do |message|
              stop = stop_result
              return stop if stop
              outcome = accept(message)
              return outcome if outcome
            end
            return Result.result("failed", "unexpected_output")
          end
        rescue Failure => error
          Result.result("failed", error.message)
        rescue SystemCallError, IOError, ArgumentError
          Result.result("failed", @session ? "interrupted" : "spawn_failed")
        rescue StandardError
          Result.unknown_fallback
        ensure
          cancel_pending
          Session.cleanup(@session, grace: @grace, clock: @clock)
        end

        private

        def stop_result
          begin
            return Result.result("cancelled", nil) if @cancelled.call
          rescue StandardError
            raise Failure, "cancel_check_failed"
          end
          return unless @clock.call >= @deadline

          @on_challenge ? Result.result("expired", nil) : Result.result("failed", "timeout")
        end

        def send_message(object)
          @session.write_stdin("#{JSON.generate(object)}\n")
        end

        def read_messages
          out, err = @session.read_available
          @bytes += out.bytesize + err.bytesize
          raise Failure, "output_capped" if @bytes > @limit

          @buffer << out
          messages = []
          while (index = @buffer.index("\n"))
            line = @buffer.slice!(0, index + 1).strip
            next if line.empty?

            parsed = JSON.parse(line)
            raise Failure, "unexpected_output" unless parsed.is_a?(Hash)
            messages << parsed
          end
          messages
        rescue JSON::ParserError
          raise Failure, "unexpected_output"
        end

        def accept(message)
          if message["method"] == "account/login/completed"
            completion = message["params"]
            raise Failure, "unexpected_output" unless completion.is_a?(Hash) && valid_id?(completion["loginId"])
            if @login_id && completion["loginId"] == @login_id
              accept_completion(completion)
            elsif @phase == :start
              raise Failure, "output_capped" if @early_completions.size >= 32
              @early_completions[completion["loginId"]] = completion
            end
            return nil
          end
          expected = { initialize: 1, start: 3, account: 2 }[@phase]
          return nil unless expected && message["id"] == expected
          raise Failure, "unexpected_output" if message.key?("error")

          payload = message["result"]
          raise Failure, "unexpected_output" unless payload.is_a?(Hash)
          case @phase
          when :initialize
            send_message(method: "initialized", params: {})
            if @on_challenge
              @phase = :start
              send_message(id: 3, method: "account/login/start", params: { type: "chatgptDeviceCode" })
            else
              read_account
            end
          when :start
            accept_start(payload)
          when :account
            return account_result(payload)
          end
          nil
        end

        def accept_start(payload)
          unless payload["type"] == "chatgptDeviceCode" && valid_id?(payload["loginId"])
            raise Failure, "auth_rejected"
          end
          # Keep the opaque id so even a rejected URL or callback can cancel
          # the pending operation. It is never exposed or stored by Rails.
          @login_id = payload["loginId"]
          challenge = Result.challenge(provider: "codex", verification_uri: payload["verificationUrl"],
                                       user_code: payload["userCode"], input_required: false)
          raise Failure, "challenge_rejected" unless challenge && challenge["user_code"]
          @phase = :completion
          begin
            @on_challenge.call(challenge)
          rescue StandardError
            raise Failure, "callback_failed"
          end
          early = @early_completions.delete(@login_id)
          @early_completions.clear
          accept_completion(early) if early
        end

        def accept_completion(payload)
          return unless @phase == :completion
          unless [true, false].include?(payload["success"]) &&
                 (payload["error"].nil? || payload["error"].is_a?(String))
            raise Failure, "unexpected_output"
          end
          @completed = true
          raise Failure, "auth_rejected" unless payload["success"] == true && payload["error"].nil?
          read_account
        end

        def read_account
          @phase = :account
          send_message(id: 2, method: "account/read", params: { refreshToken: false })
        end

        def account_result(payload)
          unless payload.key?("account") && [true, false].include?(payload["requiresOpenaiAuth"])
            raise Failure, "unexpected_output"
          end
          account = payload["account"]
          return Result.result("disconnected", nil) if account.nil?
          raise Failure, "unexpected_output" unless account.is_a?(Hash)
          raise Failure, "auth_rejected" unless account["type"] == "chatgpt"
          unless account["planType"].is_a?(String) && !account["planType"].empty? &&
                 (account["email"].nil? || account["email"].is_a?(String))
            raise Failure, "unexpected_output"
          end
          Result.result("connected", nil)
        end

        def valid_id?(value)
          value.is_a?(String) && value.bytesize.between?(1, 256) && !value.match?(/[[:cntrl:]]/)
        end

        def cancel_pending
          return unless @session && @login_id && !@completed

          send_message(id: 4, method: "account/login/cancel", params: { loginId: @login_id })
          deadline = @clock.call + 0.25
          while @session.alive? && @clock.call < deadline
            @session.wait_output(0.05)
            break if read_messages.any? { |message| message["id"] == 4 }
          end
        rescue StandardError
          nil
        end
      end
    end
  end
end
