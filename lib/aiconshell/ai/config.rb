# frozen_string_literal: true

require "tmpdir"

module Aiconshell
  module Ai
    # Static configuration for the Ai ports. Resolved from explicit keyword
    # arguments first, then environment overrides, then compiled defaults.
    # Private auth locations point at dedicated volumes; their *contents* are
    # never read by this library (presence checks only).
    #
    # Muse is XDG-rooted: muse_home is the XDG config home (the directory
    # *containing* the "muse" directory), because both the `muse` launcher
    # and the native runtime resolve auth.json as
    # $XDG_CONFIG_HOME/muse/auth.json (else $HOME/.config/muse/auth.json;
    # the launcher also honors $MUSE_AUTH_PATH). There is no MUSE_CONFIG_DIR.
    # See ChildEnv and docs/ai-providers.md.
    class Config
      PROVIDERS = %w[claude codex muse].freeze
      LAYERS = %w[interaction coordination execution].freeze

      DEFAULT_TIMEOUT = 300
      DEFAULT_MAX_OUTPUT_BYTES = 1_000_000
      DEFAULT_KILL_GRACE_SECONDS = 5
      DEFAULT_PATH = "/usr/bin:/bin:/usr/local/bin"

      MUSE_DEFAULT_MODEL = "muse-spark-1.3-contributor"
      MUSE_DEFAULT_EFFORT = "max"

      attr_reader :claude_executable, :codex_executable, :muse_executable,
        :claude_home, :codex_home, :muse_home,
        :controlled_home, :default_timeout, :max_output_bytes,
        :kill_grace_seconds, :child_path, :muse_default_model,
        :muse_default_effort

      def self.default
        new
      end

      # rubocop:disable Metrics/ParameterLists
      def initialize(
        claude_executable: nil,
        codex_executable: nil,
        muse_executable: nil,
        claude_home: nil,
        codex_home: nil,
        muse_home: nil,
        controlled_home: nil,
        default_timeout: DEFAULT_TIMEOUT,
        max_output_bytes: DEFAULT_MAX_OUTPUT_BYTES,
        kill_grace_seconds: DEFAULT_KILL_GRACE_SECONDS,
        child_path: DEFAULT_PATH,
        muse_default_model: MUSE_DEFAULT_MODEL,
        muse_default_effort: MUSE_DEFAULT_EFFORT
      )
        @claude_executable = claude_executable || ENV.fetch("AICONSHELL_CLAUDE_BIN", "claude")
        @codex_executable = codex_executable || ENV.fetch("AICONSHELL_CODEX_BIN", "codex")
        @muse_executable = muse_executable || ENV.fetch("AICONSHELL_MUSE_BIN", "muse")
        @claude_home = expand(claude_home || ENV["CLAUDE_CONFIG_DIR"] ||
          ENV["AICONSHELL_CLAUDE_HOME"] || "~/.claude")
        @codex_home = expand(codex_home || ENV["CODEX_HOME"] ||
          ENV["AICONSHELL_CODEX_HOME"] || "~/.codex")
        # Explicit app override wins over the generic XDG variable.
        @muse_home = expand(muse_home || ENV["AICONSHELL_MUSE_HOME"] ||
          default_muse_home)
        @controlled_home = expand(controlled_home || ENV["AICONSHELL_AI_HOME"] ||
          File.join(Dir.tmpdir, "aiconshell-ai-home"))
        @default_timeout = default_timeout
        @max_output_bytes = max_output_bytes
        @kill_grace_seconds = kill_grace_seconds
        @child_path = child_path
        @muse_default_model = muse_default_model || MUSE_DEFAULT_MODEL
        @muse_default_effort = muse_default_effort || MUSE_DEFAULT_EFFORT
      end
      # rubocop:enable Metrics/ParameterLists

      def executable_for(provider)
        case provider
        when "claude" then claude_executable
        when "codex" then codex_executable
        when "muse" then muse_executable
        else raise UnknownProvider, provider
        end
      end

      def home_for(provider)
        case provider
        when "claude" then claude_home
        when "codex" then codex_home
        when "muse" then muse_home
        else raise UnknownProvider, provider
        end
      end

      # Directory holding the provider's auth material: used for presence
      # diagnostics and workspace-overlap rejection. For Muse this is the
      # "muse" subdirectory of the XDG config home.
      def auth_dir_for(provider)
        case provider
        when "claude", "codex" then home_for(provider)
        when "muse" then File.join(muse_home, "muse")
        else raise UnknownProvider, provider
        end
      end

      private

      def default_muse_home
        xdg = ENV["XDG_CONFIG_HOME"]
        return xdg unless xdg.nil? || xdg.empty?

        "~/.config"
      end

      def expand(path)
        File.expand_path(path)
      end
    end
  end
end
