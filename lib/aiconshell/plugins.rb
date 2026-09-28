# frozen_string_literal: true

# In-process external-service plugins for aiconshell.
#
# Entry point (see docs/architecture.md, "Plugins"):
#
#   registry = Aiconshell::Plugins::Registry.default
#   registry.catalog
#   registry.invoke(plugin: "github", operation: "latest_events",
#                   input: { "scope" => "owner/repo" }, context: {})
#
# Pure-Ruby root for the plugin lane. Rails integration (when the foundation
# lane lands) requires this file; Zeitwerk and explicit require must not both
# define these constants.
#
# Runtime dependency: json_schemer (JSON Schema validation).
# Test dependency: smartest. Everything else is Ruby stdlib.
require_relative "plugins/errors"
require_relative "plugins/schemas"
require_relative "plugins/http"
require_relative "plugins/base"
require_relative "plugins/registry"
require_relative "plugins/github"
require_relative "plugins/discord"

module Aiconshell
  module Plugins
    VERSION = "0.1.0"
  end
end
