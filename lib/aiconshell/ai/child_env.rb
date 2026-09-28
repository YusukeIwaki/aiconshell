# frozen_string_literal: true

require "tmpdir"

module Aiconshell
  module Ai
    # Builds the controlled environment for AI CLI subprocesses. The child
    # environment is constructed from scratch: application credentials
    # (database, integration accounts, API keys, ...) are never inherited.
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
          # Verified against the installed launcher (a shell script:
          # credential_path="${MUSE_AUTH_PATH:-$credential_default}",
          # default $XDG_CONFIG_HOME/muse/auth.json else
          # $HOME/.config/muse/auth.json) and the native runtime, which
          # resolves the same XDG/HOME-rooted muse/auth.json and honors
          # neither MUSE_CONFIG_DIR nor MUSE_AUTH_PATH. XDG_CONFIG_HOME
          # is the one mapping both stages honor; MUSE_AUTH_PATH pins
          # the launcher to the same file. The neutral HOME is kept.
          env["XDG_CONFIG_HOME"] = config.muse_home
          env["MUSE_AUTH_PATH"] = File.join(config.auth_dir_for("muse"), "auth.json")
        end

        env
      end
    end
  end
end
