# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "tmpdir"

module Aiconshell
  module Ai
    # Executes one structured request against a subscription CLI and returns
    # the schema-validated answer as a JSON-compatible Hash.
    #
    # The process runner is injected (fake in tests, ProcessRunner in
    # production). Prompts, raw stdout and auth material never appear in
    # errors, logs or return envelopes beyond redacted excerpts.
    class Runner
      def initialize(registry: Registry.default, process_runner: ProcessRunner.new, config: Config.default)
        @registry = registry
        @process_runner = process_runner
        @config = config
      end

      # @param provider ["claude","codex","muse"]
      # @param prompt [String] task prompt (data, never shell-interpolated)
      # @param schema [Hash] JSON Schema describing an object
      # @param workspace [String] absolute path of the isolated workspace
      # @param layer [String] interaction, coordination or execution
      # @param model [String, nil] provider model override from LayerPolicy
      # @param effort [String, nil] reasoning effort override from LayerPolicy
      # @param instructions [String, nil] policy instructions (system prompt or folded into prompt)
      # @param timeout [Numeric, nil] seconds; defaults to config
      # @return [Hash] schema-validated answer
      def call(provider:, prompt:, schema:, workspace:, layer:, model: nil, effort: nil, instructions: nil, timeout: nil)
        adapter = @registry.adapter_for(provider)
        timeout = validate_inputs!(provider, prompt, schema, workspace, layer, timeout)

        unless @registry.configured?(provider)
          raise NotConfigured.new(provider, @registry.diagnose(provider))
        end
        executable = @registry.resolve_executable(provider)
        raise NotConfigured.new(provider, @registry.diagnose(provider)) if executable.nil?

        Dir.mktmpdir("aiconshell-ai-") do |dir|
          files = prepare_files(adapter, dir, schema, prompt, instructions)
          invocation = adapter.invocation(
            prompt: prompt, schema: schema, model: model, effort: effort,
            instructions: instructions, workspace: workspace, layer: layer,
            config: @config, files: files, executable: executable
          )
          env = ChildEnv.build(provider: provider, config: @config)
          result = run_child(provider, invocation, env, workspace, timeout)
          raise TimeoutError.new(provider, timeout) if result.timed_out?
          if result.stdout_truncated?
            raise InvalidOutput.new(provider, "stdout exceeded #{@config.max_output_bytes} bytes")
          end
          parsed = adapter.parse_output(
            stdout: result.stdout, stderr: result.stderr,
            exit_status: result.exit_status, files: files, config: @config
          )
          unless parsed.is_a?(Hash)
            raise InvalidOutput.new(provider, "adapter must return a Hash")
          end

          SchemaValidator.validate!(parsed, schema, provider: provider)
        end
      end

      private

      def validate_inputs!(provider, prompt, schema, workspace, layer, timeout)
        unless Config::LAYERS.include?(layer)
          raise ArgumentError, "layer must be one of #{Config::LAYERS.join(", ")}, got #{layer.inspect}"
        end
        unless prompt.is_a?(String) && !prompt.strip.empty?
          raise ArgumentError, "prompt must be a non-empty String"
        end
        validate_schema!(schema)
        validate_workspace!(workspace)
        timeout = @config.default_timeout if timeout.nil?
        unless timeout.is_a?(Numeric) && timeout.positive?
          raise ArgumentError, "timeout must be a positive number of seconds"
        end
        timeout
      end

      def validate_schema!(schema)
        raise ArgumentError, "schema must be a Hash, got #{schema.class}" unless schema.is_a?(Hash)

        type = schema["type"] || schema[:type]
        return if type.nil? || type == "object"

        raise ArgumentError, "schema must describe an object, got type #{type.inspect}"
      end

      # The application body and private auth locations must never serve as
      # the AI workspace: it has to be a dedicated, isolated directory.
      def validate_workspace!(workspace)
        unless workspace.is_a?(String) && Pathname.new(workspace).absolute?
          raise ArgumentError, "workspace must be an absolute path"
        end
        unless Dir.exist?(workspace)
          raise ArgumentError, "workspace does not exist: #{workspace.inspect}"
        end
        raise ArgumentError, "workspace must not be the filesystem root" if File.expand_path(workspace) == "/"

        Config::PROVIDERS.each do |provider|
          home = @config.home_for(provider)
          next if home.nil? || home.empty?

          if overlap?(workspace, home)
            raise ArgumentError, "workspace must not overlap the #{provider} auth location"
          end
        end
      end

      def overlap?(workspace, home)
        expanded_workspace = File.expand_path(workspace)
        expanded_home = File.expand_path(home)
        expanded_workspace == expanded_home ||
          expanded_workspace.start_with?("#{expanded_home}/") ||
          expanded_home.start_with?("#{expanded_workspace}/")
      end

      def prepare_files(adapter, dir, schema, prompt, instructions)
        files = {}
        if adapter.needs_schema_file?
          files[:schema_file] = write_secure_file(dir, "schema.json", JSON.generate(schema))
        end
        if adapter.needs_prompt_file?
          files[:prompt_file] = write_secure_file(
            dir, "prompt.txt", adapter.prompt_document(prompt: prompt, instructions: instructions)
          )
        end
        files[:output_file] = File.join(dir, "output.txt") if adapter.needs_output_file?
        files
      end

      def write_secure_file(dir, name, content)
        path = File.join(dir, name)
        File.write(path, content, encoding: Encoding::UTF_8)
        File.chmod(0o600, path)
        path
      end

      def run_child(provider, invocation, env, workspace, timeout)
        @process_runner.call(
          argv: invocation.fetch(:argv),
          env: env,
          cwd: workspace,
          stdin_data: invocation[:stdin_data],
          timeout: timeout,
          max_output_bytes: @config.max_output_bytes,
          kill_grace_seconds: @config.kill_grace_seconds
        )
      rescue SystemCallError, IOError => error
        raise ExecutionFailed.new(
          provider, exit_status: nil,
          kind: Redactor.failure_kind(error.message),
          excerpt: Redactor.excerpt(error.message, max_chars: @config.error_excerpt_chars)
        )
      end
    end
  end
end
