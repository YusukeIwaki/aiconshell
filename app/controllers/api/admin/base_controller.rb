# frozen_string_literal: true

module Api
  module Admin
    # Shared guard for the JSON admin API. Uses a dedicated ancestry
    # (ActionController::API) so UI session and CSRF behavior is untouched.
    #
    # - Token comes from ENV["ADMIN_API_TOKEN"] only.
    # - Comparison is constant-time via SHA256 digests.
    # - Fail closed: blank or missing token denies every request.
    # - Only Bearer is accepted; Basic and cookies are never a fallback.
    class BaseController < ActionController::API
      before_action :authenticate_api_token!

      private

      def authenticate_api_token!
        expected = ENV["ADMIN_API_TOKEN"].to_s
        return render_unauthorized if expected.empty?

        header = request.headers["Authorization"].to_s
        scheme, _, given = header.partition(" ")
        return render_unauthorized unless scheme == "Bearer" && given.present?

        return if secure_match?(given, expected)

        render_unauthorized
      end

      def render_unauthorized
        render json: { error: "unauthorized" }, status: :unauthorized
      end

      def secure_match?(given, expected)
        given_digest = Digest::SHA256.hexdigest(given.to_s)
        expected_digest = Digest::SHA256.hexdigest(expected.to_s)
        ActiveSupport::SecurityUtils.secure_compare(given_digest, expected_digest)
      end
    end
  end
end
