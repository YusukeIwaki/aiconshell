# frozen_string_literal: true

module Aiconshell
  module Ai
    # Claude Code subscription CLI adapter.
    #
    # Verified against `claude --help` (2.1.280) and the official CLI
    # reference / structured-outputs docs:
    #   claude -p --output-format json --json-schema '<schema>' [...]
    # with the prompt on stdin (no positional prompt argument) prints one
    # result envelope; the validated object arrives in `structured_output`
    # when subtype is "success". Stdin delivery keeps large prompts and
    # prompts starting with "-" working, and keeps user text out of argv
    # (never visible in the process list).
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
          { argv: argv, stdin_data: prompt }
        end

        def parse_output(stdout:, stderr:, exit_status:, files:, config:)
          check_exit!(stdout: stdout, stderr: stderr, exit_status: exit_status, config: config)
          envelope = parse_json_object!(stdout.to_s.strip, "claude output")
          if envelope["type"] == "result" && envelope["subtype"] != "success"
            kind = Redactor.failure_kind(envelope_text(envelope, stderr))
            raise ExecutionFailed.new(id, exit_status: exit_status, kind: kind)
          end

          structured = envelope["structured_output"]
          return structured if structured.is_a?(Hash)

          if envelope["type"] == "result"
            raise InvalidOutput.new(id, "claude result is missing structured_output")
          end

          raise InvalidOutput.new(id, "unexpected claude response shape")
        end

        private

        # Interaction/coordination: every tool disabled in plan mode, plus
        # --strict-mcp-config (no --mcp-config is ever passed, so no MCP
        # server loads) and --disable-slash-commands (no skills). This is
        # CLI policy, not OS confinement: see docs/ai-providers.md.
        # Execution keeps file tools plus Bash; acceptEdits auto-approves
        # workspace edits while anything that would prompt is denied
        # (--permission-prompts none). --add-dir *grants* tool access to
        # the workspace; it does not confine Bash/Read to it.
        def layer_flags(workspace, layer)
          if execution_layer?(layer)
            ["--tools", "Read,Edit,Write,Glob,Grep,Bash",
             "--permission-mode", "acceptEdits",
             "--add-dir", workspace]
          else
            ["--tools", "", "--permission-mode", "plan",
             "--strict-mcp-config", "--disable-slash-commands"]
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
