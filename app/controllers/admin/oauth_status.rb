# frozen_string_literal: true

require "aiconshell/oauth" unless defined?(Aiconshell::Oauth::ErrorCodes)

module Admin
  # Presentation adapter for user-delegated OAuth connections (issue #23).
  #
  # Operator intent (begin/disconnect/status) is delegated to the
  # foundation Oauth::AuthService; this module only owns the
  # operator-facing test seam (an injectable service instance) and the
  # read-only status rows for the admin page. Business Task/TaskRun,
  # LayerPolicy, and the plugin Registry are never touched.
  #
  # Rows carry no secrets: connection fields come from
  # Oauth::AuthService#public_status and the connecting flag comes from a
  # live-attempt existence check.
  module OauthStatus
    PROVIDERS = %w[atlassian microsoft].freeze

    PROVIDER_NAMES = {
      "atlassian" => "Atlassian（Jira Cloud）",
      "microsoft" => "Microsoft（Teams / Graph）"
    }.freeze

    FIXED_TARGETS = {
      "atlassian" => "Jira Cloud（運用設定の固定 cloud ID）",
      "microsoft" => "Entra テナント（固定・仕事/学校アカウント）"
    }.freeze

    REQUIRED_ENV_NAMES = {
      "atlassian" => %w[OAUTH_ATLASSIAN_CLIENT_ID OAUTH_ATLASSIAN_CLIENT_SECRET
                        OAUTH_ATLASSIAN_CLOUD_ID OAUTH_ATLASSIAN_REDIRECT_URI].freeze,
      "microsoft" => %w[OAUTH_MICROSOFT_CLIENT_ID OAUTH_MICROSOFT_CLIENT_SECRET
                        OAUTH_MICROSOFT_TENANT_ID OAUTH_MICROSOFT_REDIRECT_URI].freeze
    }.freeze

    FALLBACK_STATUS = {
      "provider" => nil,
      "state" => "unknown",
      "connected" => false,
      "principal" => "",
      "display_name" => "",
      "tenant" => nil,
      "cloud" => nil,
      "scopes" => [],
      "token_expires_at" => nil,
      "error_code" => nil,
      "generation" => 0,
      "configured" => false
    }.freeze

    class << self
      # Test seam: inject a real Oauth::AuthService wired to boundary
      # fixtures (scripted HTTP transport, test env). Production leaves
      # this unset so the service reads ENV with the real transport.
      attr_writer :auth_service

      def auth_service
        return @auth_service if defined?(@auth_service) && @auth_service

        Oauth::AuthService.new
      end

      def reset!
        remove_instance_variable(:@auth_service) if defined?(@auth_service)
      end

      def known_provider?(value)
        PROVIDERS.include?(value.to_s)
      end

      def provider_name(provider)
        PROVIDER_NAMES.fetch(provider.to_s, provider.to_s)
      end

      def fixed_target(provider)
        FIXED_TARGETS.fetch(provider.to_s, "")
      end

      def required_env_names(provider)
        REQUIRED_ENV_NAMES.fetch(provider.to_s, []).dup
      end

      # One row per provider for the index page. Never raises and never
      # carries secrets.
      def rows
        PROVIDERS.map do |provider|
          status = safe_status(provider)
          status.merge(
            "connecting" => connecting?(provider),
            "required_env" => required_env_names(provider)
          )
        end
      end

      # True while a live (unexpired, unconsumed-terminal) authorization
      # attempt exists for the provider. Used only for the 接続中 badge.
      def connecting?(provider)
        OauthAuthAttempt.active.where(provider: provider.to_s)
                        .where("expires_at > ?", Time.current).exists?
      rescue StandardError
        false
      end

      private

      def safe_status(provider)
        status = auth_service.public_status(provider: provider)
        status.is_a?(Hash) ? status : FALLBACK_STATUS.merge("provider" => provider.to_s)
      rescue StandardError
        FALLBACK_STATUS.merge("provider" => provider.to_s)
      end
    end
  end
end
