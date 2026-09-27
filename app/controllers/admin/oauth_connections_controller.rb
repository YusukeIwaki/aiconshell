# frozen_string_literal: true

require "uri"

module Admin
  # Operator management of user-delegated OAuth connections (issue #23).
  # Hands intent to Oauth::AuthService (begin/disconnect/status) and never
  # creates Task/TaskRun, never touches business jobs or the plugin
  # Registry. Basic auth and real CSRF verification stay enabled through
  # BaseController; nothing here disables them.
  #
  # Log safety: the authorize redirect carries state/code_challenge, so it
  # is delivered with a manually assigned Location header instead of
  # redirect_to — redirect_to would emit "Redirected to <url>" into the
  # Rails log through redirect_to.action_controller. Callback query
  # parameters are covered by the :code/:state/:error filter_parameters
  # entry, and the authorize URL itself is never rendered into HTML.
  class OauthConnectionsController < BaseController
    include OauthBrowserSession

    before_action :set_private_headers

    TRUSTED_AUTHORIZE_HOSTS = {
      "atlassian" => %w[auth.atlassian.com],
      "microsoft" => %w[login.microsoftonline.com]
    }.freeze

    def index
      @rows = OauthStatus.rows
    end

    # Starts one authorization attempt and sends the browser to the fixed
    # provider authorize URL. The URL comes only from the foundation
    # service (fixed provider configuration, never callback input); the
    # host is re-checked here so a misconfiguration can never become an
    # open redirect.
    def connect
      provider = checked_provider
      return if provider.nil?

      begun = oauth.begin(provider: provider, browser_session_id: oauth_browser_session_id)
      url = begun["authorize_url"].to_s
      unless trusted_authorize_url?(provider, url)
        redirect_to admin_oauth_connections_path,
                    alert: "連携開始できませんでした。プロバイダー設定を確認してください。"
        return
      end
      redirect_to_provider(url)
    rescue Aiconshell::Oauth::Error => e
      redirect_to admin_oauth_connections_path, alert: connect_alert(e.code)
    rescue StandardError
      redirect_to admin_oauth_connections_path,
                  alert: "連携開始できませんでした。設定を確認してください。"
    end

    # Local disconnect: stops in-app use and discards tokens. Revoking
    # consent on the provider side is a separate operator action; the
    # notice says so.
    def disconnect
      provider = checked_provider
      return if provider.nil?

      oauth.disconnect(provider: provider)
      redirect_to admin_oauth_connections_path,
                  notice: "解除しました。このアプリでの利用を停止し、トークンを破棄しました。" \
                          "プロバイダー側の同意取り消しは別途行ってください。"
    rescue Aiconshell::Oauth::Error => e
      redirect_to admin_oauth_connections_path, alert: connect_alert(e.code)
    rescue StandardError
      redirect_to admin_oauth_connections_path,
                  alert: "解除できませんでした。もう一度お試しください。"
    end

    private

    def oauth
      OauthStatus.auth_service
    end

    def checked_provider
      provider = params[:provider].to_s
      return provider if OauthStatus.known_provider?(provider)

      redirect_to admin_oauth_connections_path, alert: "不明なプロバイダーです。"
      nil
    end

    # Manual 302 without redirect_to instrumentation, so the
    # state/code_challenge-bearing authorize URL never reaches the
    # "Redirected to" log line. no-referrer keeps the admin page URL out
    # of the provider's Referer as well.
    def redirect_to_provider(url)
      response.headers["Location"] = url
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
      head :found
    end

    def trusted_authorize_url?(provider, url)
      uri = URI.parse(url)
      return false unless uri.is_a?(URI::HTTPS)
      return false if uri.userinfo && !uri.userinfo.empty?

      TRUSTED_AUTHORIZE_HOSTS.fetch(provider.to_s, []).include?(uri.host.to_s.downcase)
    rescue URI::InvalidURIError
      false
    end

    # Foundation codes map to fixed Japanese strings (never exception or
    # provider text); unknown codes fall back to a fixed message.
    def connect_alert(code)
      text = Aiconshell::Oauth::ErrorCodes.japanese_code(code)
      text.empty? ? "連携開始できませんでした。設定を確認してください。" : text
    end

    def set_private_headers
      response.headers["Cache-Control"] = "no-store"
      # same-origin keeps CSRF Origin/Referer checks working in IAB browsers
      # (no-referrer sends Origin: null and breaks POSTs). The authorize
      # redirect itself uses no-referrer (see redirect_to_provider).
      response.headers["Referrer-Policy"] = "same-origin"
    end
  end
end
