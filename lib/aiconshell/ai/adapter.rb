# frozen_string_literal: true

require "json"

module Aiconshell
  module Ai
    # Base class for provider adapters. Each adapter owns one subscription
    # CLI: argv construction (array only, never shell), tool policy per
    # layer, and stdout/output-file parsing into a JSON-compatible Hash.
    class Adapter
      class << self
        def id
          raise NotImplementedError
        end

        def display_name
          raise NotImplementedError
        end

        # Absolute executable path, or nil when not installed. Pure PATH
        # lookup; never shells out and never executes the binary.
        def resolve_executable(config)
          configured = config.executable_for(id)
          return expand_file(configured) if configured.include?(File::SEPARATOR)

          parent_path.split(File::PATH_SEPARATOR).each do |dir|
            next if dir.nil? || dir.empty?

            candidate = File.expand_path(configured, dir)
            return candidate if executable_file?(candidate)
          end
          nil
        end

        # Presence-only diagnostic: executable on PATH plus private auth
        # location mounted. Subscription validity stays a runtime concern.
        def configured?(config)
          !resolve_executable(config).nil? && Dir.exist?(config.auth_dir_for(id))
        end

        def diagnose(config)
          executable = config.executable_for(id)
          home = config.auth_dir_for(id)
          found = !resolve_executable(config).nil?
          present = Dir.exist?(home)
          {
            id: id,
            executable: executable,
            executable_found: found,
            home: home,
            home_present: present,
            configured: found && present
          }
        end

        def needs_schema_file?
          false
        end

        def needs_prompt_file?
          false
        end

        def needs_output_file?
          false
        end

        # Full prompt document for stdin delivery or --prompt-file CLIs.
        def prompt_document(prompt:, instructions:)
          return prompt if instructions.nil? || instructions.strip.empty?

          "Instructions:\n#{instructions.strip}\n\nTask:\n#{prompt}"
        end

        # @return [{argv: Array<String>, stdin_data: String/nil}]
        def invocation(prompt:, schema:, model:, effort:, instructions:, workspace:, layer:, config:, files:, executable:)
          raise NotImplementedError
        end

        # @return [Hash] JSON-compatible parsed output
        def parse_output(stdout:, stderr:, exit_status:, files:, config:)
          raise NotImplementedError
        end

        private

        def parent_path
          ENV.fetch("PATH", "")
        end

        def expand_file(path)
          expanded = File.expand_path(path)
          executable_file?(expanded) ? expanded : nil
        end

        def executable_file?(path)
          File.file?(path) && File.executable?(path)
        end

        def validate_effort!(effort, allowed)
          return if effort.nil?
          return if allowed.include?(effort)

          raise ArgumentError, "invalid effort #{effort.inspect} for #{id} (expected one of #{allowed.join(", ")})"
        end

        def validate_optional_text!(value, name)
          return if value.nil?
          unless value.is_a?(String) && !value.strip.empty?
            raise ArgumentError, "#{name} must be a non-empty String or nil"
          end
          raise ArgumentError, "#{name} must not contain NUL bytes" if value.include?("\0")
        end

        def check_exit!(stdout:, stderr:, exit_status:, config:)
          return if exit_status == 0

          # stderr is classified, then discarded: no excerpt is kept.
          kind = Redactor.failure_kind(stderr)
          raise ExecutionFailed.new(id, exit_status: exit_status, kind: kind)
        end

        def parse_json_object!(text, what)
          parsed = JSON.parse(text.to_s)
          unless parsed.is_a?(Hash)
            raise InvalidOutput.new(id, "#{what} must be a JSON object, got #{parsed.class}")
          end
          parsed
        rescue JSON::ParserError
          # Parser messages can echo the offending input: discard them.
          raise InvalidOutput.new(id, "#{what} is not valid JSON")
        end

        # Bounded read: at most max_bytes+1 are ever loaded, so a
        # runaway CLI cannot exhaust memory via the result file.
        def read_output_file!(path, what, max_bytes:)
          unless path && File.file?(path)
            raise InvalidOutput.new(id, "#{what} was not produced by the CLI")
          end
          raw = File.read(path, max_bytes + 1, 0, encoding: Encoding::UTF_8)
          if raw.bytesize > max_bytes
            raise InvalidOutput.new(id, "#{what} exceeded #{max_bytes} bytes")
          end
          content = raw.scrub.strip
          raise InvalidOutput.new(id, "#{what} is empty") if content.empty?

          content
        end

        def execution_layer?(layer)
          layer == "execution"
        end
      end
    end
  end
end
