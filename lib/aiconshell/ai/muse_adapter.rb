# frozen_string_literal: true

module Aiconshell
  module Ai
    # Muse Code subscription CLI adapter.
    #
    # Verified against `muse exec --help` (Muse Code 1.4.0) plus offline
    # `--provider echo` probes (no login, no billed calls):
    #   muse exec --json --output-schema <file> --prompt-file <file> \
    #     --workspace <dir> --model <id> --reasoning-effort <effort>
    # stdout is JSONL MSP wire records; the final answer is the `text` of the
    # last `run.terminal.*` event (schema-shaped JSON under --output-schema).
    class MuseAdapter < Adapter
      class << self
        def id
          "muse"
        end

        def display_name
          "Muse Code"
        end

        EFFORTS = %w[none minimal low medium high xhigh max ultra].freeze

        def needs_schema_file?
          true
        end

        def needs_prompt_file?
          true
        end

        def invocation(prompt:, schema:, model:, effort:, instructions:, workspace:, layer:, config:, files:, executable:)
          validate_optional_text!(model, "model")
          validate_effort!(effort, EFFORTS)

          argv = [executable, "exec", "--json",
                 "--output-schema", files.fetch(:schema_file),
                 "--prompt-file", files.fetch(:prompt_file),
                 "--workspace", workspace,
                 "--model", model || config.muse_default_model,
                 "--reasoning-effort", effort || config.muse_default_effort]
          # User-input cancellation and tool approval are separate settings.
          # Both must be noninteractive, including execution. The sandbox
          # remains enabled and foreign personal capabilities are excluded.
          argv += ["--user-input-auto-resolve", "--approval-mode", "never",
                   "--no-foreign-personal-context"]
          unless execution_layer?(layer)
            argv += ["--disable-write", "--disable-shell", "--disable-web-tools"]
          end
          argv << "--no-session-log"
          { argv: argv, stdin_data: nil }
        end

        def parse_output(stdout:, stderr:, exit_status:, files:, config:)
          check_exit!(stdout: stdout, stderr: stderr, exit_status: exit_status, config: config)
          terminal = last_terminal_event(stdout.to_s)
          raise InvalidOutput.new(id, "muse event stream has no terminal event") if terminal.nil?

          payload = terminal["payload"]
          payload = {} unless payload.is_a?(Hash)
          unless payload["terminal"] == "completed"
            reason = payload["reason"].to_s
            reason = stderr.to_s if reason.strip.empty?
            raise ExecutionFailed.new(
              id, exit_status: exit_status, kind: Redactor.failure_kind(reason)
            )
          end

          text = payload["text"]
          raise InvalidOutput.new(id, "muse terminal event has no text") unless text.is_a?(String)

          parse_json_object!(text.strip, "muse final answer")
        end

        private

        def last_terminal_event(stdout)
          terminal = nil
          stdout.each_line.with_index(1) do |line, number|
            next if line.strip.empty?

            event = JSON.parse(line)
            terminal = event if terminal_event?(event)
          rescue JSON::ParserError
            raise InvalidOutput.new(id, "muse event stream has malformed JSON on line #{number}")
          end
          terminal
        end

        def terminal_event?(event)
          return false unless event.is_a?(Hash)

          type = event["payload_type"].to_s
          return true if type.start_with?("run.terminal")

          payload = event["payload"]
          payload.is_a?(Hash) && payload["kind"] == "run_terminal"
        end
      end
    end
  end
end
