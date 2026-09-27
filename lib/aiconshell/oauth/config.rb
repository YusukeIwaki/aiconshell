# frozen_string_literal: true

require "uri"

module Aiconshell
  module Oauth
    # Fixed provider configuration for user-delegated OAuth (issue #22).
    # One operating environment connects one user per provider; the Jira
    # Cloud ID and the Entra tenant are fixed by operator settings and can
    # never be chosen by callback input. Secrets are read from the injected
    # env (value or *_FILE path); only variable *names* are ever reported.
    class Config
      ATLASSIAN_AUTH_URL = "https://auth.atlassian.com/authorize"
      ATLASSIAN_TOKEN_URL = "https://auth.atlassian.com/oauth/token"
      ATLASSIAN_RESOURCES_URL = "https://api.atlassian.com/oauth/token/accessible-resources"
      ATLASSIAN_JIRA_API_HOST = "api.atlassian.com"
      ATLASSIAN_REQUIRED_SCOPES = %w[
        offline_access read:jira-work write:jira-work read:jira-user
      ].freeze
      ATLASSIAN_AUDIENCE = "api.atlassian.com"

      MICROSOFT_AUTH_HOST = "login.microsoftonline.com"
      MICROSOFT_GRAPH_HOST = "graph.microsoft.com"
      MICROSOFT_REQUIRED_SCOPES = %w[
        offline_access User.Read ChannelMessage.Read.All
        ChannelMessage.Send Chat.Read ChatMessage.Send
      ].freeze

      # Delegated API scopes proven at verify/refresh time. The
      # offline_access string is NOT an API permission: it only requests a
      # refresh token, so the token-response scope echo must not be required
      # to contain it (Entra defines an omitted scope as "the requested
      # scopes"). Requiring it would reject valid consents.
      ATLASSIAN_DELEGATED_SCOPES = %w[
        read:jira-work write:jira-work read:jira-user
      ].freeze
      MICROSOFT_DELEGATED_SCOPES = %w[
        User.Read ChannelMessage.Read.All
        ChannelMessage.Send Chat.Read ChatMessage.Send
      ].freeze

      # Fixed-tenant contract: these placeholders would allow any tenant
      # and must never be accepted as configuration.
      FORBIDDEN_TENANTS = %w[common organizations consumers].freeze

      # Fixed provider settings. Values (including client_id) never appear
      # in inspection: only names and the configured flag are safe to show.
      class ProviderConfig
        attr_reader :provider, :client_id, :client_secret, :redirect_uri,
                    :cloud_id, :tenant_id, :scopes

        def initialize(provider:, client_id:, client_secret:, redirect_uri:,
                       cloud_id:, tenant_id:, scopes:)
          @provider = provider.to_s
          @client_id = client_id
          @client_secret = client_secret
          @redirect_uri = redirect_uri
          @cloud_id = cloud_id
          @tenant_id = tenant_id
          @scopes = Array(scopes).map(&:to_s).freeze
          freeze
        end

        def configured?
          missing.empty?
        end

        def missing
          names = []
          names << "client_id" if @client_id.nil? || @client_id.to_s.empty?
          names << "client_secret" if @client_secret.nil? || @client_secret.to_s.empty?
          names << "redirect_uri" if @redirect_uri.nil? || @redirect_uri.to_s.empty?
          if @provider == "atlassian"
            names << "cloud_id" if @cloud_id.nil? || @cloud_id.to_s.empty?
          else
            names << "tenant_id" if @tenant_id.nil? || @tenant_id.to_s.empty?
          end
          names
        end

        def to_h
          {
            provider: @provider,
            client_id: @client_id,
            client_secret: @client_secret,
            redirect_uri: @redirect_uri,
            cloud_id: @cloud_id,
            tenant_id: @tenant_id,
            scopes: @scopes.dup
          }
        end

        def inspect
          "#<Aiconshell::Oauth::Config::ProviderConfig " \
            "provider=#{@provider.inspect} configured=#{configured?.inspect}>"
        end

        def to_s
          inspect
        end
      end

      def initialize(env:)
        @env = env
      end

      def provider(name)
        case name.to_s
        when "atlassian" then atlassian
        when "microsoft" then microsoft
        else raise Error.new("provider_error", "unknown oauth provider")
        end
      end

      def atlassian
        ProviderConfig.new(
          provider: "atlassian",
          client_id: value("OAUTH_ATLASSIAN_CLIENT_ID"),
          client_secret: secret("OAUTH_ATLASSIAN_CLIENT_SECRET", "OAUTH_ATLASSIAN_CLIENT_SECRET_FILE"),
          redirect_uri: value("OAUTH_ATLASSIAN_REDIRECT_URI"),
          cloud_id: value("OAUTH_ATLASSIAN_CLOUD_ID"),
          tenant_id: nil,
          scopes: ATLASSIAN_REQUIRED_SCOPES.dup
        )
      end

      def microsoft
        ProviderConfig.new(
          provider: "microsoft",
          client_id: value("OAUTH_MICROSOFT_CLIENT_ID"),
          client_secret: secret("OAUTH_MICROSOFT_CLIENT_SECRET", "OAUTH_MICROSOFT_CLIENT_SECRET_FILE"),
          redirect_uri: value("OAUTH_MICROSOFT_REDIRECT_URI"),
          cloud_id: nil,
          tenant_id: value("OAUTH_MICROSOFT_TENANT_ID"),
          scopes: MICROSOFT_REQUIRED_SCOPES.dup
        )
      end

      def inspect
        "#<Aiconshell::Oauth::Config providers=#{Aiconshell::Oauth::PROVIDERS.inspect}>"
      end

      def to_s
        inspect
      end

      # Fixed token endpoint for a provider. Callback input can never
      # select this; unknown providers raise before any network use.
      # A forbidden multi-tenant placeholder is never accepted here.
      def token_url(provider)
        case provider.to_s
        when "atlassian" then ATLASSIAN_TOKEN_URL
        when "microsoft"
          tenant = microsoft.tenant_id.to_s
          raise ConfigMissing.new("microsoft", ["OAUTH_MICROSOFT_TENANT_ID"]) if tenant.empty?
          raise ProviderError.new("tenant_mismatch") if forbidden_tenant?(tenant)

          "https://#{MICROSOFT_AUTH_HOST}/#{encode_path(tenant)}/oauth2/v2.0/token"
        else raise Error.new("provider_error", "unknown oauth provider")
        end
      end

      def authorize_url(provider)
        case provider.to_s
        when "atlassian" then ATLASSIAN_AUTH_URL
        when "microsoft"
          tenant = microsoft.tenant_id.to_s
          raise ConfigMissing.new("microsoft", ["OAUTH_MICROSOFT_TENANT_ID"]) if tenant.empty?
          raise ProviderError.new("tenant_mismatch") if forbidden_tenant?(tenant)

          "https://#{MICROSOFT_AUTH_HOST}/#{encode_path(tenant)}/oauth2/v2.0/authorize"
        else raise Error.new("provider_error", "unknown oauth provider")
        end
      end

      def forbidden_tenant?(tenant)
        FORBIDDEN_TENANTS.include?(tenant.to_s.strip.downcase)
      end

      def graph_me_url
        "https://#{MICROSOFT_GRAPH_HOST}/v1.0/me"
      end

      # A redirect URI is operator-fixed configuration, not user input.
      # It must be https (loopback http is allowed only when explicitly
      # configured for local testing), carry no userinfo and no fragment.
      def valid_redirect_uri?(value)
        return false unless value.is_a?(String) && !value.empty? && value.length <= 2048
        return false if value.match?(/[\u0000-\u0020]/)

        uri = URI.parse(value)
        return false unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
        return false if uri.userinfo && !uri.userinfo.empty?
        return false if uri.fragment && !uri.fragment.empty?

        return true if uri.is_a?(URI::HTTPS)
        return true if loopback_http?(uri)

        false
      rescue URI::InvalidURIError
        false
      end

      # Env variable *names* missing for a provider (values never exposed).
      def missing_env_names(provider)
        names = case provider.to_s
                when "atlassian"
                  %w[OAUTH_ATLASSIAN_CLIENT_ID OAUTH_ATLASSIAN_CLIENT_SECRET
                     OAUTH_ATLASSIAN_CLOUD_ID OAUTH_ATLASSIAN_REDIRECT_URI]
                when "microsoft"
                  %w[OAUTH_MICROSOFT_CLIENT_ID OAUTH_MICROSOFT_CLIENT_SECRET
                     OAUTH_MICROSOFT_TENANT_ID OAUTH_MICROSOFT_REDIRECT_URI]
                else return ["provider"]
                end
        names.reject do |name|
          alt = secret_file_alt(name)
          present?(lookup(name)) || (alt && present?(lookup(alt)))
        end
      end

      private

      def value(name)
        result = lookup(name)
        result.nil? || result.to_s.empty? ? nil : result.to_s
      end

      def secret(name, file_name)
        direct = lookup(name)
        return direct.to_s unless direct.nil? || direct.to_s.empty?
        return nil if file_name.nil?

        path = lookup(file_name)
        return nil if path.nil? || path.to_s.empty?

        begin
          text = File.read(path.to_s).strip
          text.empty? ? nil : text
        rescue SystemCallError
          nil
        end
      end

      def lookup(name)
        if @env.respond_to?(:[])
          @env[name]
        else
          nil
        end
      end

      def present?(val)
        !val.nil? && !val.to_s.empty?
      end

      def secret_file_alt(name)
        case name
        when "OAUTH_ATLASSIAN_CLIENT_SECRET" then "OAUTH_ATLASSIAN_CLIENT_SECRET_FILE"
        when "OAUTH_MICROSOFT_CLIENT_SECRET" then "OAUTH_MICROSOFT_CLIENT_SECRET_FILE"
        else nil
        end
      end

      def loopback_http?(uri)
        return false unless uri.is_a?(URI::HTTP) && !uri.is_a?(URI::HTTPS)

        host = uri.host.to_s.downcase
        host == "localhost" || host == "127.0.0.1" || host == "::1"
      end

      def encode_path(segment)
        URI.encode_www_form_component(segment).gsub("+", "%20")
      end
    end
  end
end
