# frozen_string_literal: true

require "json"
require "uri"
require_relative "../plugins/errors"
require_relative "../plugins/http"

module Aiconshell
  module Oauth
    # Atlassian OAuth 2.0 (3LO) for Jira Cloud, confidential client.
    #
    # Official flow (https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/):
    # authorize with audience + prompt=consent, exchange the code with the
    # client secret, verify the fixed cloud ID and granted scopes through
    # accessible-resources, then resolve the principal through that same
    # cloud's /myself. There is no PKCE parameter in the official 3LO spec,
    # so this provider never sends or accepts one.
    module Atlassian
      CLOUD_ID_PATTERN = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

      module_function

      def authorize_url(config:, state:)
        provider = config.atlassian
        raise ConfigMissing.new("atlassian", config.missing_env_names("atlassian")) unless provider.configured?
        raise ConfigMissing.new("atlassian", ["OAUTH_ATLASSIAN_REDIRECT_URI"]) unless config.valid_redirect_uri?(provider.redirect_uri)

        params = {
          "audience" => Config::ATLASSIAN_AUDIENCE,
          "client_id" => provider.client_id,
          "scope" => provider.scopes.join(" "),
          "redirect_uri" => provider.redirect_uri,
          "state" => state.to_s,
          "response_type" => "code",
          "prompt" => "consent"
        }
        "#{Config::ATLASSIAN_AUTH_URL}?#{URI.encode_www_form(params)}"
      end

      def exchange_code(transport:, config:, code:, redirect_uri:)
        provider = config.atlassian
        raise ConfigMissing.new("atlassian", config.missing_env_names("atlassian")) unless provider.configured?
        raise ProviderError.new("unexpected_response") unless code.is_a?(String) && !code.empty?
        raise ProviderError.new("unexpected_response") unless redirect_uri == provider.redirect_uri

        body = JSON.generate(
          "grant_type" => "authorization_code",
          "client_id" => provider.client_id,
          "client_secret" => provider.client_secret,
          "code" => code,
          "redirect_uri" => redirect_uri
        )
        payload = post_token(transport, config.token_url("atlassian"), body, operation: :exchange)
        TokenSet.validate_exchange!(payload, provider: "atlassian")
      end

      def refresh(transport:, config:, refresh_token:)
        provider = config.atlassian
        raise ConfigMissing.new("atlassian", config.missing_env_names("atlassian")) unless provider.configured?
        raise ProviderError.new("unexpected_response") unless refresh_token.is_a?(String) && !refresh_token.empty?

        body = JSON.generate(
          "grant_type" => "refresh_token",
          "client_id" => provider.client_id,
          "client_secret" => provider.client_secret,
          "refresh_token" => refresh_token
        )
        payload = post_token(transport, config.token_url("atlassian"), body, operation: :refresh)
        TokenSet.validate_exchange!(payload, provider: "atlassian")
      end

      # Verifies the fixed cloud and Jira scopes, then resolves the
      # principal from that same cloud. Returns a Hash with String keys
      # (principal, display_name, cloud_id, scopes). The accessible-resources
      # scope list proves Jira permissions only: offline_access is a token
      # grant flag, not an API permission, and is never required here.
      # Provider JSON types are strict: numerics/Hashes are never coerced
      # into principals or grants. Failures raise ProviderError with
      # cloud_mismatch / scope_mismatch / principal_mismatch and never echo
      # provider text.
      def verify_connection(transport:, config:, access_token:)
        provider = config.atlassian
        raise ConfigMissing.new("atlassian", config.missing_env_names("atlassian")) unless provider.configured?
        raise ProviderError.new("unexpected_response") unless access_token.is_a?(String) && !access_token.empty?

        cloud_id = provider.cloud_id.to_s
        raise ProviderError.new("cloud_mismatch") unless CLOUD_ID_PATTERN.match?(cloud_id)

        resources = get_json(transport, Config::ATLASSIAN_RESOURCES_URL, access_token)
        unless resources.is_a?(Array)
          raise ProviderError.new("unexpected_response")
        end
        entry = resources.find { |item| item.is_a?(Hash) && item["id"].is_a?(String) && item["id"] == cloud_id }
        raise ProviderError.new("cloud_mismatch") if entry.nil?

        raw_scopes = entry["scopes"]
        unless raw_scopes.is_a?(Array) && raw_scopes.all? { |scope| scope.is_a?(String) }
          raise ProviderError.new("unexpected_response")
        end
        granted = raw_scopes.join(" ")
        unless TokenSet.granted_scopes?(granted, Config::ATLASSIAN_DELEGATED_SCOPES)
          raise ProviderError.new("scope_mismatch")
        end

        myself_url = "https://#{Config::ATLASSIAN_JIRA_API_HOST}/ex/jira/#{cloud_id}/rest/api/3/myself"
        myself = get_json(transport, myself_url, access_token)
        unless myself.is_a?(Hash)
          raise ProviderError.new("unexpected_response")
        end
        account_id = myself["accountId"]
        unless account_id.is_a?(String) && !account_id.empty?
          raise ProviderError.new("principal_mismatch")
        end
        display_raw = myself["displayName"]
        display_name = display_raw.is_a?(String) ? display_raw : ""

        {
          "principal" => account_id,
          "display_name" => display_name,
          "cloud_id" => cloud_id,
          "scopes" => TokenSet.scope_text(granted)
        }
      end

      def post_token(transport, url, body, operation:)
        guard_url!(url, [Config::ATLASSIAN_TOKEN_URL])
        response = raw_request(transport, "POST", url,
                               { "Content-Type" => "application/json", "Accept" => "application/json" },
                               body, operation: operation)
        parse_json!(response)
      end

      def get_json(transport, url, access_token)
        allowed = [Config::ATLASSIAN_RESOURCES_URL,
                   "https://#{Config::ATLASSIAN_JIRA_API_HOST}"]
        guard_url!(url, allowed)
        response = raw_request(transport, "GET", url,
                               { "Authorization" => "Bearer #{access_token}", "Accept" => "application/json" },
                               nil, operation: :verify)
        parse_json!(response)
      end

      def guard_url!(url, allowed)
        Aiconshell::Plugins::Http.check_host!(url, allowed)
      rescue Aiconshell::Plugins::HostRejected
        raise ProviderError.new("unexpected_response")
      end

      # Transport failures map to safe codes. The shared transport raises
      # HttpError without the response body, so revocation is classified by
      # status: a 400/401 from the refresh grant almost always means the
      # refresh token expired or was revoked (RFC 6749 invalid_grant), and
      # Atlassian documents 403 Forbidden + error invalid_grant for dead
      # refresh tokens as well. Other 4xx stay provider_rejected and 5xx
      # stay provider_error. Raw bodies and error_descriptions never leave
      # the transport.
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

      private_class_method :post_token, :get_json, :guard_url!, :raw_request, :parse_json!
    end
  end
end
