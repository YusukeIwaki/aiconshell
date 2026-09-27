# frozen_string_literal: true

require_relative "oauth_test_support"

# Shared scaffolding for OAuth admin UI tests (issue #23). The admin
# pages and the public callback resolve their service through
# Admin::OauthStatus, so tests install a REAL Oauth::AuthService wired to
# boundary fixtures only (scripted HTTP transport, synthetic env,
# isolated secret store, fake event sink). Controllers, session binding,
# CSRF, routes, and PostgreSQL rows stay real.
module OauthAdminSupport
  module_function

  def install_service(env: OauthTestSupport.test_env)
    ctx = OauthTestSupport.services(env: env)
    Admin::OauthStatus.auth_service = ctx[:auth]
    ctx
  end

  def uninstall_service
    Admin::OauthStatus.reset!
  end

  def with_service(env: OauthTestSupport.test_env)
    ctx = install_service(env: env)
    yield ctx
  ensure
    uninstall_service
  end

  # Raw state out of a begin redirect Location header.
  def state_from_location(location)
    query = URI.parse(location.to_s).query.to_s
    URI.decode_www_form(query).to_h["state"].to_s
  end
end
