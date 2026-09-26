# frozen_string_literal: true

module Aiconshell
  # Ai provides subscription-CLI execution ports for Claude Code, Codex and
  # Muse Code behind one deterministic Ruby contract.
  #
  #   Aiconshell::Ai::Registry.default.providers      # => ["claude", "codex", "muse"]
  #   Aiconshell::Ai::Registry.default.configured?("codex") # => true/false
  #   Aiconshell::Ai::Runner.new.call(
  #     provider: "codex", prompt: "...", schema: {},
  #     workspace: "/controlled/path", layer: "coordination"
  #   ) # => JSON-compatible Hash, schema validated
  #
  # There is intentionally no API-key fallback: unconfigured providers stay
  # selectable (policies may reference them) and fail at execution time.
  module Ai
  end
end

require_relative "ai/errors"
require_relative "ai/config"
require_relative "ai/redactor"
require_relative "ai/child_env"
require_relative "ai/process_runner"
require_relative "ai/schema_validator"
require_relative "ai/adapter"
require_relative "ai/claude_adapter"
require_relative "ai/codex_adapter"
require_relative "ai/muse_adapter"
require_relative "ai/registry"
require_relative "ai/runner"
