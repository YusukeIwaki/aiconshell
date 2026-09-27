# frozen_string_literal: true

# User-delegated OAuth2 connection foundation (issue #22).
#
# Pure-Ruby ports for Atlassian (Jira Cloud 3LO) and Microsoft (Entra
# authorization code + PKCE S256, confidential client) user consent.
# Rails persistence and orchestration live in app/models/oauth_* and
# app/services/oauth/*. This lane never touches Task/TaskRun, LayerPolicy,
# the Interaction/Coordination/Execution split, or the shared plugin
# Registry default (delegated plugins register in later issues).
#
#   config = Aiconshell::Oauth::Config.new(env: ENV)
#   config.atlassian.configured? # => true/false (names only, never values)
#
# Runtime dependency: json (stdlib-adjacent). HTTP boundary is injected:
# transports implement `request(method:, url:, headers:, body:)`.
require_relative "oauth/errors"
require_relative "oauth/secret_box"
require_relative "oauth/state"
require_relative "oauth/pkce"
require_relative "oauth/config"
require_relative "oauth/token_set"
require_relative "oauth/binding"
require_relative "oauth/atlassian"
require_relative "oauth/microsoft"

module Aiconshell
  module Oauth
    VERSION = "0.1.0"
    PROVIDERS = %w[atlassian microsoft].freeze
  end
end
