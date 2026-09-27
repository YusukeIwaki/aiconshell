# frozen_string_literal: true

# Provider-fixed OAuth callback (issue #23). The provider redirects the
# operator's browser here after consent, so this endpoint intentionally
# has no admin Basic auth (the provider cannot supply credentials).
# Forgery protection comes from the session-bound one-time state checked
# by Oauth::AuthService, never from a CSRF token: this GET carries none.
#
# Every outcome redirects to the query-free admin page so code/state
# never stay in the address bar. error_description is never read,
# rendered, logged, or stored. Callback parameters must be short strings;
# Array/Hash/oversized values are treated as absent so the foundation
# rejects them with a safe classification.
class OauthCallbacksController < ApplicationController
  include OauthBrowserSession

  MAX_CALLBACK_PARAM_BYTES = 4096

  before_action :set_private_headers

  def show
    provider = params[:provider].to_s
    unless Admin::OauthStatus.known_provider?(provider)
      redirect_to root_path, alert: "不明なプロバイダーです。"
      return
    end

    Admin::OauthStatus.auth_service.callback(
      provider: provider,
      state: callback_text(params[:state]),
      code: callback_text(params[:code]),
      browser_session_id: oauth_browser_session_id,
      error: callback_text(params[:error])
    )
    redirect_to admin_oauth_connections_path,
                notice: "接続しました。接続先と権限を確認してください。"
  rescue Aiconshell::Oauth::Error => e
    redirect_to admin_oauth_connections_path, alert: callback_alert(e.code)
  rescue StandardError
    redirect_to admin_oauth_connections_path,
                alert: "接続できませんでした。もう一度連携開始からお試しください。"
  end

  private

  def callback_text(value)
    return nil unless value.is_a?(String)
    return nil if value.empty?
    return nil if value.bytesize > MAX_CALLBACK_PARAM_BYTES

    value
  end

  # Foundation codes map to fixed Japanese strings (never exception or
  # provider text); unknown codes fall back to a fixed message.
  def callback_alert(code)
    text = Aiconshell::Oauth::ErrorCodes.japanese_code(code)
    text.empty? ? "接続できませんでした。もう一度連携開始からお試しください。" : text
  end

  def set_private_headers
    response.headers["Cache-Control"] = "no-store"
    # The callback URL carries code/state: never send it as a Referer to
    # the admin page or anywhere else.
    response.headers["Referrer-Policy"] = "no-referrer"
  end
end
