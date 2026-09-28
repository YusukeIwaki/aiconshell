# frozen_string_literal: true

# Integration accounts an AI engineer may use (issue #28): GitHub Apps and
# Discord. Credentials live in the database, never in the environment.
# This module is the default credential source for Interaction services;
# tests inject a fake source responding to .env_for(plugin) instead of
# touching the database.
module Accounts
  PLUGINS = %w[github discord].freeze

  class << self
    # Singleton account row for a plugin, or nil when unsupported or never
    # saved. Read-only: never creates rows as a side effect.
    def account_for(plugin)
      case plugin.to_s
      when "github" then GithubAppsAccount.ordered.first
      when "discord" then DiscordAccount.ordered.first
      end
    end

    def configured?(plugin)
      account = account_for(plugin)
      !account.nil? && account.configured?
    end

    # Environment-shaped credential hash for plugin adapters (keys only,
    # values only in memory). Empty when unconfigured; adapters then fail
    # with CredentialsMissing exactly as before.
    def env_for(plugin)
      account = account_for(plugin)
      account ? account.credential_env : {}
    end

    # Environment-shaped credentials for one plugin call. Built-in
    # plugins (github/discord) read the credential source only: the
    # registry environment is never a fallback. Registered extensions
    # keep their own environment contract with the source overlaid, so
    # custom required_env setups keep working.
    def invoke_env(plugin, registry:, source: self)
      provided = source.env_for(plugin.to_s)
      return provided if PLUGINS.include?(plugin.to_s)

      base = registry.respond_to?(:env) ? registry.env : {}
      base = base.to_h if base.respond_to?(:to_h) && !base.is_a?(Hash)
      base.is_a?(Hash) ? base.merge(provided) : provided
    end

    # Trusted invoke context for poll/query/outbound/health_check: capability
    # scopes plus the database-backed credentials.
    def invoke_context(plugin, operation, registry:)
      Interaction::PluginAccess.context(plugin, operation, registry: registry).merge(
        "env" => invoke_env(plugin, registry: registry)
      )
    end
  end
end
