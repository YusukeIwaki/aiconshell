# frozen_string_literal: true

require "tmpdir"

module Aiconshell
  module Ai
    # Builds the controlled environment for AI CLI subprocesses. The child
    # environment is constructed from scratch: application credentials
    # (database, GitHub, Jira, Teams, API keys, ...) are never inherited.
    # Only a minimal locale/PATH set plus the calling provider's subscription
    # credential home is exposed.
    module ChildEnv
      LOCALE_ENV = {
        "LANG" => "C.UTF-8",
        "LC_ALL" => "C.UTF-8"
      }.freeze

      module_function

      def build(provider:, config: Config.default)
        unless Config::PROVIDERS.include?(provider)
          raise UnknownProvider, provider
        end

        env = {
          "PATH" => config.child_path,
          "HOME" => config.controlled_home,
          "TMPDIR" => Dir.tmpdir
        }.merge(LOCALE_ENV)

        case provider
        when "claude"
          env["CLAUDE_CONFIG_DIR"] = config.claude_home
        when "codex"
          env["CODEX_HOME"] = config.codex_home
        when "muse"
          env["MUSE_CONFIG_DIR"] = config.muse_home
          env["XDG_CONFIG_HOME"] = config.muse_xdg_config_home if config.muse_xdg_config_home
        end

        env
      end
    end
  end
end
