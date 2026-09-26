# frozen_string_literal: true

module Aiconshell
  module Ai
    # Claude Code subscription CLI adapter.
    #
    # Verified against `claude --help` (2.1.280) and the official CLI
    # reference / structured-outputs docs:
    #   claude -p --output-format json --json-schema '<schema>' [...]
    # prints one result envelope; the validated object arrives in
    # `structured_output` when subtype is "success".
    class ClaudeAdapter < Adapter
      class << self
        def id
          "claude"
        end

        def display_name
          "Claude Code"
        end

        EFFORTS = %w[low medium high xhigh max].freeze

        def invocation(prompt:, schema:, model:, effort:, instructions:, workspace:, layer:, config:, files:, executable:)
          validate_optional_text!(model, "model")
          validate_effort!(effort, EFFORTS)
          validate_optional_text!(instructions, "instructions") unless instructions.nil?

          argv = [executable, "-p", "--output-format", "json",
                 "--json-schema", JSON.generate(schema)]
          argv += ["--model", model] if model
          argv += ["--effort", effort] if effort
          argv += ["--system-prompt", instructions] if instructions && !instructions.strip.empty?
          argv += layer_flags(workspace, layer)
          argv += ["--permission-prompts", "none", "--no-session-persistence"]
          argv << prompt
          { argv: argv, stdin_data: nil }
        end

        def parse_output(stdout:, stderr:, exit_status:, files:, config:)
          check_exit!(stdout: stdout, stderr: stderr, exit_status: exit_status, config: config)
          envelope = parse_json_object!(stdout.to_s.strip, "claude output")
          if envelope["type"] == "result" && envelope["subtype"] != "success"
            kind = Redactor.failure_kind(envelope_text(envelope, stderr))
            raise ExecutionFailed.new(
              id, exit_status: exit_status, kind: kind,
              excerpt: Redactor.excerpt(envelope_text(envelope, stderr), max_chars: config.error_excerpt_chars)
            )
          end

          structured = envelope["structured_output"]
          return structured if structured.is_a?(Hash)

          if envelope["type"] == "result"
            raise InvalidOutput.new(id, "claude result is missing structured_output")
          end

          raise InvalidOutput.new(id, "unexpected claude response shape")
        end

        private

        # Interaction/coordination run with every tool disabled in plan mode.
        # Execution keeps file tools plus Bash; acceptEdits auto-approves
        # workspace edits while anything that would prompt is denied, and
        # file tools stay confined to the workspace directories.
        def layer_flags(workspace, layer)
          if execution_layer?(layer)
            ["--tools", "Read,Edit,Write,Glob,Grep,Bash",
             "--permission-mode", "acceptEdits",
             "--add-dir", workspace]
          else
            ["--tools", "", "--permission-mode", "plan"]
          end
        end

        def envelope_text(envelope, stderr)
          errors = envelope["errors"]
          detail = errors.is_a?(Array) ? errors.map(&:to_s).join(" ") : envelope["result"].to_s
          detail = stderr.to_s if detail.strip.empty?
          detail
        end
      end
    end
  end
end
