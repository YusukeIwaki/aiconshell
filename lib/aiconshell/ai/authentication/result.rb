# frozen_string_literal: true

module Aiconshell
  module Ai
    module Authentication
      # Fixed vocabularies and JSON Schemas for authentication results and
      # device-code challenges. Every Hash crossing the Runner boundary is
      # built here and validated, so callers only ever see the documented
      # shapes with fixed classification strings.
      module Result
        # Terminal states. `status` only returns the first four; `login`
        # additionally returns `cancelled` (cancel callback fired) and
        # `expired` (deadline passed or the CLI reported an expired code).
        STATES = %w[connected disconnected unavailable failed cancelled expired].freeze

        # Fixed failure classifications. `error_code` is nil unless state is
        # `failed`; no raw CLI text, token or exception message ever appears.
        ERROR_CODES = %w[
          invalid_provider invalid_argument
          spawn_failed timeout unexpected_output output_capped
          challenge_rejected auth_rejected
          callback_failed input_failed cancel_check_failed
          interrupted unknown
        ].freeze

        RESULT_SCHEMA = {
          "type" => "object",
          "properties" => {
            "state" => { "type" => "string", "enum" => STATES },
            "error_code" => { "type" => %w[string null], "enum" => ERROR_CODES + [nil] }
          },
          "required" => %w[state error_code],
          "additionalProperties" => false
        }.freeze

        # Challenge shape delivered to `on_challenge`. `verification_uri` is
        # an official per-provider HTTPS URL (query preserved, needed for the
        # flow) and `user_code` the short code the user approves or pastes.
        # Both are transient authentication guidance, never stored.
        CHALLENGE_SCHEMA = {
          "type" => "object",
          "properties" => {
            "verification_uri" => { "type" => "string", "minLength" => 1, "maxLength" => 2048 },
            "user_code" => { "type" => %w[string null], "maxLength" => 64 },
            "input_required" => { "type" => "boolean" }
          },
          "required" => %w[verification_uri user_code input_required],
          "additionalProperties" => false
        }.freeze

        # Last-resort envelope for the Runner's outermost rescue. Used as-is
        # (never re-validated) so a validator bug cannot recurse.
        FALLBACK_UNKNOWN = { "state" => "failed", "error_code" => "unknown" }.freeze

        MAX_USER_CODE_CHARS = 64

        module_function

        def result(state, error_code)
          hash = { "state" => state, "error_code" => error_code }
          SchemaValidator.validate!(hash, RESULT_SCHEMA, provider: "authentication")
          hash
        end

        # Builds a validated challenge Hash, or nil when the candidate fails
        # the provider URL policy or the structural checks.
        def challenge(provider:, verification_uri:, user_code:, input_required:)
          return nil unless user_code.nil? || user_code.is_a?(String)
          if user_code.is_a?(String) &&
              (user_code.empty? || user_code.length > MAX_USER_CODE_CHARS ||
                user_code.match?(/[\x00-\x1F\x7F]/))
            return nil
          end
          return nil unless input_required == true || input_required == false

          uri = UrlPolicy.validate(provider, verification_uri)
          return nil if uri.nil?

          hash = { "verification_uri" => uri, "user_code" => user_code, "input_required" => input_required }
          SchemaValidator.validate!(hash, CHALLENGE_SCHEMA, provider: "authentication")
          hash
        end

        def unknown_fallback
          FALLBACK_UNKNOWN.dup
        end
      end
    end
  end
end
