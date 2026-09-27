# frozen_string_literal: true

require "json"
require "uri"
require_relative "../plugins/errors"
require_relative "../plugins/http"

module Aiconshell
  module Oauth
    # Microsoft identity platform authorization code flow for a fixed Entra
    # tenant (work/school accounts), confidential client with PKCE S256.
    #
    # Official flow (https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow):
    # authorize with code_challenge + prompt=consent, exchange the code with
    # client_secret + code_verifier, then resolve the principal through
    # Graph /me. Token claims (including unverified JWTs) are never used as
    # the trust root; the principal comes from the authenticated /me call
    # and the tenant comes from fixed operator configuration.
    module Microsoft
      TENANT_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9.\-]{0,63}\z/

      module_function

      def fixed_tenant!(tenant)
        text = tenant.to_s
        raise ProviderError.new("tenant_mismatch") unless TENANT_PATTERN.match?(text)
        if Aiconshell::Oauth::Config::FORBIDDEN_TENANTS.include?(text.strip.downcase)
          raise ProviderError.new("tenant_mismatch")
        end

        text
      end

      def authorize_url(config:, state:, challenge:)
        provider = config.microsoft
        raise ConfigMissing.new("microsoft", config.missing_env_names("microsoft")) unless provider.configured?
        raise ConfigMissing.new("microsoft", ["OAUTH_MICROSOFT_REDIRECT_URI"]) unless config.valid_redirect_uri?(provider.redirect_uri)
        fixed_tenant!(provider.tenant_id)
        raise ProviderError.new("unexpected_response") unless challenge.is_a?(String) && !challenge.empty?

        params = {
          "client_id" => provider.client_id,
          "response_type" => "code",
          "redirect_uri" => provider.redirect_uri,
          "scope" => provider.scopes.join(" "),
          "state" => state.to_s,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "prompt" => "consent"
        }
        "#{config.authorize_url("microsoft")}?#{URI.encode_www_form(params)}"
      end

      def exchange_code(transport:, config:, code:, redirect_uri:, verifier:)
        provider = config.microsoft
        raise ConfigMissing.new("microsoft", config.missing_env_names("microsoft")) unless provider.configured?
        fixed_tenant!(provider.tenant_id)
        raise ProviderError.new("unexpected_response") unless code.is_a?(String) && !code.empty?
        raise ProviderError.new("unexpected_response") unless redirect_uri == provider.redirect_uri
        raise ProviderError.new("unexpected_response") unless Pkce.valid_verifier?(verifier)

        body = URI.encode_www_form(
          "client_id" => provider.client_id,
          "scope" => provider.scopes.join(" "),
          "code" => code,
          "redirect_uri" => redirect_uri,
          "grant_type" => "authorization_code",
          "code_verifier" => verifier,
          "client_secret" => provider.client_secret
        )
        payload = post_token(transport, config.token_url("microsoft"), body, operation: :exchange)
        TokenSet.validate_exchange!(payload, provider: "microsoft")
      end

      def refresh(transport:, config:, refresh_token:)
        provider = config.microsoft
        raise ConfigMissing.new("microsoft", config.missing_env_names("microsoft")) unless provider.configured?
        fixed_tenant!(provider.tenant_id)
        raise ProviderError.new("unexpected_response") unless refresh_token.is_a?(String) && !refresh_token.empty?

        body = URI.encode_www_form(
          "client_id" => provider.client_id,
          "scope" => provider.scopes.join(" "),
          "refresh_token" => refresh_token,
          "grant_type" => "refresh_token",
          "client_secret" => provider.client_secret
        )
        payload = post_token(transport, config.token_url("microsoft"), body, operation: :refresh)
        TokenSet.validate_exchange!(payload, provider: "microsoft")
      end

      # Resolves the principal through Graph /me over the fixed Graph
      # origin. Returns a Hash with String keys (principal, display_name,
      # tenant_id, scopes). The tenant is fixed configuration, never a
      # token claim. JWTs are never parsed here. The token-response scope
      # echo is optional per the Entra spec: nil (omitted) means "the
      # requested scopes" and is accepted; an explicit string must cover
      # the delegated API scopes. offline_access is never required in the
      # echo. Provider JSON types are strict.
      def verify_connection(transport:, config:, access_token:, granted_scope: nil)
        provider = config.microsoft
        raise ConfigMissing.new("microsoft", config.missing_env_names("microsoft")) unless provider.configured?
        raise ProviderError.new("unexpected_response") unless access_token.is_a?(String) && !access_token.empty?

        tenant = fixed_tenant!(provider.tenant_id)

        me = get_json(transport, config.graph_me_url, access_token)
        unless me.is_a?(Hash)
          raise ProviderError.new("unexpected_response")
        end
        user_id = me["id"]
        unless user_id.is_a?(String) && !user_id.empty?
          raise ProviderError.new("principal_mismatch")
        end
        display_raw = me["displayName"]
        display_name = display_raw.nil? ? "" : (display_raw.is_a?(String) ? display_raw : raise(ProviderError.new("unexpected_response")))

        unless granted_scope.nil? || granted_scope.is_a?(String)
          raise ProviderError.new("unexpected_response")
        end
        if granted_scope.nil?
          scope_text = provider.scopes.join(" ")
        else
          scope_text = TokenSet.scope_list(granted_scope).join(" ")
          unless TokenSet.granted_scopes?(scope_text, Config::MICROSOFT_DELEGATED_SCOPES)
            raise ProviderError.new("scope_mismatch")
          end
        end

        {
          "principal" => user_id,
          "display_name" => display_name,
          "tenant_id" => tenant,
          "scopes" => scope_text
        }
      end

      def post_token(transport, url, body, operation:)
        guard_token_url!(url)
        response = raw_request(transport, "POST", url,
                               { "Content-Type" => "application/x-www-form-urlencoded",
                                 "Accept" => "application/json" },
                               body, operation: operation)
        parse_json!(response)
      end

      def get_json(transport, url, access_token)
        Aiconshell::Plugins::Http.check_host!(url, ["https://#{Config::MICROSOFT_GRAPH_HOST}"])
        response = raw_request(transport, "GET", url,
                               { "Authorization" => "Bearer #{access_token}", "Accept" => "application/json" },
                               nil, operation: :verify)
        parse_json!(response)
      rescue Aiconshell::Plugins::HostRejected
        raise ProviderError.new("unexpected_response")
      end

      def guard_token_url!(url)
        uri = URI.parse(url.to_s)
        unless uri.is_a?(URI::HTTPS) &&
            uri.host.to_s.downcase == Config::MICROSOFT_AUTH_HOST &&
            uri.path.to_s.match?(%r{\A/[^/]+/oauth2/v2\.0/token\z})
          raise ProviderError.new("unexpected_response")
        end
      rescue URI::InvalidURIError
        raise ProviderError.new("unexpected_response")
      end

      # Status-based classification without response bodies: a
      # 400/401/403 from the refresh grant maps to invalid_grant
      # (expired/revoked token), other 4xx to provider_rejected, 5xx to
      # provider_error. Raw bodies and error_descriptions never leave the
      # transport.
      def raw_request(transport, method, url, headers, body, operation:)
        transport.request(method: method, url: url, headers: headers, body: body)
      rescue Aiconshell::Plugins::RateLimited
        raise ProviderError.new("rate_limited")
      rescue Aiconshell::Plugins::TransportTimeout
        raise ProviderError.new("timeout")
      rescue Aiconshell::Plugins::TransportError
        raise ProviderError.new("transport_error")
      rescue Aiconshell::Plugins::HttpError => e
        if operation == :refresh && (e.status == 400 || e.status == 401 || e.status == 403)
          raise ProviderError.new("invalid_grant")
        end

        raise ProviderError.new(e.status >= 500 ? "provider_error" : "provider_rejected")
      end

      def parse_json!(response)
        begin
          response.json
        rescue JSON::ParserError
          raise ProviderError.new("unexpected_response")
        end
      end

      private_class_method :post_token, :get_json, :guard_token_url!, :raw_request, :parse_json!
    end
  end
end
