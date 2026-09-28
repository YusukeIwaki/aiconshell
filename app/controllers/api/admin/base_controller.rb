# frozen_string_literal: true

module Api
  module Admin
    # Shared guard for the JSON admin API. Uses a dedicated ancestry
    # (ActionController::API) so UI session and CSRF behavior is untouched.
    #
    # - Token is the database-backed AdminApiToken singleton (digest only).
    # - Comparison is constant-time via SHA256 digests.
    # - Fail closed: no issued token denies every request.
    # - Only Bearer is accepted; Basic and cookies are never a fallback.
    class BaseController < ActionController::API
      before_action :authenticate_api_token!

      private

      def authenticate_api_token!
        record = AdminApiToken.current
        return render_unauthorized if record.nil?

        header = request.headers["Authorization"].to_s
        scheme, _, given = header.partition(" ")
        return render_unauthorized unless scheme == "Bearer" && given.present?

        return if record.matches?(given)

        render_unauthorized
      end

      def render_unauthorized
        render json: { error: "unauthorized" }, status: :unauthorized
      end
    end
  end
end
