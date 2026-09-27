# frozen_string_literal: true

module Aiconshell
  module Ai
    # Worker-side subscription authentication for the official AI CLIs.
    #
    # Runs `claude auth login --claudeai`, `codex login --device-auth` and
    # `muse login` plus their status probes inside the worker, so the web
    # tier never handles CLIs or long-lived tokens. Normal AI inference and
    # task execution stay independent of this operations-only surface.
    #
    #   runner = Aiconshell::Ai::Authentication::Runner.new(
    #     config: Aiconshell::Ai::Config.default
    #   )
    #   runner.status(provider: "codex")
    #   # => {"state" => "connected", "error_code" => nil}
    #   runner.login(provider: "muse", timeout: 900,
    #                on_challenge: ->(c) { ... }, input: -> { ... },
    #                cancelled: -> { false })
    #
    # Both entry points always return a schema-validated string-key Hash and
    # never leak raw CLI output, tokens, secret file contents or exception
    # text. See docs/ai-auth-protocol.md for the full contract.
    module Authentication
    end
  end
end

require_relative "authentication/result"
require_relative "authentication/url_policy"
require_relative "authentication/scanner"
require_relative "authentication/session"
require_relative "authentication/muse_rpc"
require_relative "authentication/runner"
