# frozen_string_literal: true

module Admin
  # Shared admin guard: HTTP Basic auth on every /admin route.
  #
  # - Credentials come from ENV["ADMIN_USERNAME"] / ENV["ADMIN_PASSWORD"].
  # - Comparison is constant-time (SHA256 digests via secure_compare, so
  #   arbitrary lengths are safe).
  # - Fail closed: when either value is unset/blank, every request is
  #   denied. No fallback user, no logged credential.
  # - CSRF protection stays at the Rails default (exception); this
  #   controller never disables it.
  class BaseController < ApplicationController
    layout "admin"

    before_action :authenticate_admin!

    private

    def authenticate_admin!
      expected_user = ENV["ADMIN_USERNAME"].to_s
      expected_pass = ENV["ADMIN_PASSWORD"].to_s
      return request_http_basic_authentication unless credentials_present?(expected_user, expected_pass)

      authenticate_with_http_basic do |user, pass|
        secure_match?(user, expected_user) & secure_match?(pass, expected_pass)
      end || request_http_basic_authentication
    end

    def credentials_present?(user, pass)
      !(user.empty? || pass.empty?)
    end

    def secure_match?(given, expected)
      given_digest = Digest::SHA256.hexdigest(given.to_s)
      expected_digest = Digest::SHA256.hexdigest(expected.to_s)
      ActiveSupport::SecurityUtils.secure_compare(given_digest, expected_digest)
    end
  end
end
