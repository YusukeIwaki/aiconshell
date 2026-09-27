# frozen_string_literal: true

module Aiconshell
  module Oauth
    # Validation for OAuth token endpoint payloads. Provider JSON shapes,
    # required scopes, positive lifetimes, and non-empty tokens are checked
    # here; failures map to safe codes and never echo provider text.
    module TokenSet
      module_function

      # Validates an authorization-code or refresh response hash. Returns a
      # normalized Hash with String keys (access_token, refresh_token,
      # expires_in, scope). The scope echo is optional per the Entra spec:
      # a missing scope means "the requested scopes" and is returned as nil
      # (omitted), distinct from an explicit scope string. A present scope
      # must be a String; numerics/Hashes are never coerced into grants.
      # Raises ProviderError on any shape violation.
      def validate_exchange!(payload, provider:)
        unless payload.is_a?(Hash)
          raise ProviderError.new("unexpected_response")
        end

        access = payload["access_token"] || payload[:access_token]
        unless access.is_a?(String) && !access.empty?
          raise ProviderError.new("unexpected_response")
        end

        expires = payload["expires_in"] || payload[:expires_in]
        seconds = to_positive_integer(expires)
        raise ProviderError.new("unexpected_response") if seconds.nil?

        refresh = payload["refresh_token"] || payload[:refresh_token]
        if !refresh.nil? && !(refresh.is_a?(String) && !refresh.empty?)
          raise ProviderError.new("unexpected_response")
        end

        raw_scope = payload.key?("scope") ? payload["scope"] : payload[:scope]
        scope = normalize_scope_field!(raw_scope)

        {
          "access_token" => access,
          "refresh_token" => refresh,
          "expires_in" => seconds,
          "scope" => scope
        }
      end

      # Normalizes the token-response scope field. Returns nil when omitted
      # (no key or nil value), otherwise the canonical space-joined text.
      # Non-String present values are a shape violation.
      def normalize_scope_field!(value)
        return nil if value.nil?

        unless value.is_a?(String)
          raise ProviderError.new("unexpected_response")
        end

        text = scope_list(value).join(" ")
        text
      end

      # Granted scopes must cover every required scope. Atlassian reports
      # granted scopes on the accessible-resources entry; Microsoft echoes
      # them in the token response scope field. Comparison is exact and
      # case-sensitive per the official scope strings.
      def granted_scopes?(granted_text, required_scopes)
        granted = scope_list(granted_text)
        Array(required_scopes).all? { |scope| granted.include?(scope.to_s) }
      end

      def scope_list(text)
        text.to_s.split(/[,\s]+/).reject(&:empty?).uniq
      end

      def scope_text(value)
        return "" if value.nil?

        scope_list(value).join(" ")
      end

      # Classifies a token endpoint error payload
      # ({"error": "invalid_grant", ...}) without exposing its description.
      def error_code_from_payload(payload)
        return nil unless payload.is_a?(Hash)

        name = (payload["error"] || payload[:error]).to_s
        case name
        when "invalid_grant" then "invalid_grant"
        when "invalid_request", "unauthorized_client", "unsupported_grant_type", "invalid_scope"
          "provider_rejected"
        when "" then nil
        else "provider_rejected"
        end
      end

      def to_positive_integer(value)
        number = case value
                 when Integer then value
                 when Float then (value == value.floor ? value.to_i : nil)
                 when String then (value.match?(/\A\d+\z/) ? value.to_i : nil)
                 else nil
                 end
        number.is_a?(Integer) && number.positive? ? number : nil
      end
    end
  end
end
