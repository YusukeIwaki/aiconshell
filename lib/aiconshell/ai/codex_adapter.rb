# frozen_string_literal: true

module Aiconshell
  module Ai
    # Codex subscription CLI adapter.
    #
    # Verified against `codex exec --help` (codex-cli 0.155.1):
    #   codex exec --json -C <workspace> --sandbox <mode> \
    #     --output-schema <file> --output-last-message <file> ... -
    # The prompt travels over stdin (`-`), keeping argv free of user text.
    # The final message lands in the output file as schema-shaped JSON.
    class CodexAdapter < Adapter
      class << self
        def id
          "codex"
        end

        def display_name
          "Codex"
        end

        EFFORTS = %w[minimal low medium high xhigh].freeze

        def needs_schema_file?
          true
        end

        def needs_output_file?
          true
        end

        def invocation(prompt:, schema:, model:, effort:, instructions:, workspace:, layer:, config:, files:, executable:)
          validate_optional_text!(model, "model")
          validate_effort!(effort, EFFORTS)

          argv = [executable, "exec", "--json",
                 "--sandbox", sandbox_mode(layer),
                 "--skip-git-repo-check",
                 "-C", workspace,
                 "--output-schema", files.fetch(:schema_file),
                 "--output-last-message", files.fetch(:output_file)]
          # All layers ignore inherited user config and user/project
          # execpolicy rules. Never --approve-for-me (it re-reviews through
          # a workspace-write sandbox) nor the dangerously-bypass flags.
          argv += ["--ignore-user-config", "--ignore-rules"]
          argv += ["-m", model] if model
          # Effort is allow-listed above, so embedding it in the TOML
          # key=value override cannot break out of the quoted string.
          argv += ["-c", "model_reasoning_effort=\"#{effort}\""] if effort
          # Enforce subscription login even if a mounted auth cache came from API login.
          argv += ["-c", 'forced_login_method="chatgpt"']
          argv << "-"
          { argv: argv, stdin_data: prompt_document(prompt: prompt, instructions: instructions) }
        end

        def parse_output(stdout:, stderr:, exit_status:, files:, config:)
          check_exit!(stdout: stdout, stderr: stderr, exit_status: exit_status, config: config)
          content = read_output_file!(
            files[:output_file], "codex last message", max_bytes: config.max_output_bytes
          )
          parse_json_object!(content, "codex last message")
        end

        private

        # Codex documents --sandbox as the policy for model-generated
        # *shell commands*. It is CLI policy, not OS confinement: the
        # container / trusted-worker boundary is the real isolation (see
        # docs/ai-providers.md).
        def sandbox_mode(layer)
          execution_layer?(layer) ? "workspace-write" : "read-only"
        end
      end
    end
  end
end
