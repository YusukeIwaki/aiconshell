# frozen_string_literal: true

require "db_helper"
require_relative "support/admin_test_support"
require_relative "../oauth/oauth_test_support"
require_relative "../oauth/oauth_admin_support"

test("oauth index requires admin auth") do |http:|
  AdminTestSupport.as_anonymous(http) do
    http.get "/admin/oauth_connections"
    expect(http.last_response.status).to eq(401)

    http.post "/admin/oauth_connections/connect", { provider: "atlassian" }
    expect(http.last_response.status).to eq(401)

    http.post "/admin/oauth_connections/disconnect", { provider: "atlassian" }
    expect(http.last_response.status).to eq(401)

    expect(OauthAuthAttempt.count).to eq(0)
    expect(OauthConnection.count).to eq(0)
  end
end

test("oauth index renders Japanese cards with unset state and no secrets") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service(env: {}) do
      http.get "/admin/oauth_connections"

      expect(http.last_response.status).to eq(200)
      body = http.last_response.body
      expect(body.include?("OAuth連携")).to eq(true)
      expect(body.include?("Atlassian（Jira Cloud）")).to eq(true)
      expect(body.include?("Microsoft（Teams / Graph）")).to eq(true)
      expect(body.scan("未設定").size >= 2).to eq(true)
      expect(body.include?("OAUTH_ATLASSIAN_CLIENT_ID")).to eq(true)
      expect(body.include?("OAUTH_MICROSOFT_TENANT_ID")).to eq(true)
      # Bot operation vs delegated operation are distinguished; no PAT UI.
      expect(body.include?("Bot運用")).to eq(true)
      expect(body.include?("OAuth2代理運用")).to eq(true)
      expect(body.include?("PAT")).to eq(true)
      expect(body.include?("個人アカウント")).to eq(true)
      # No authorize URL is rendered into the page.
      expect(body.include?("auth.atlassian.com/authorize")).to eq(false)
      expect(body.include?("login.microsoftonline.com")).to eq(false)
      # Private headers like the rest of the admin console.
      expect(http.last_response.headers["Cache-Control"]).to eq("no-store")
      expect(http.last_response.headers["Referrer-Policy"]).to eq("same-origin")
    end
  end
end

test("oauth index carries no credential values") do |http:|
  AdminTestSupport.as_admin(http) do
    ctx = OauthAdminSupport.install_service
    begin
      OauthTestSupport.connect(ctx, "atlassian")
      http.get "/admin/oauth_connections"

      expect(http.last_response.status).to eq(200)
      body = http.last_response.body
      expect(body.include?("接続済み")).to eq(true)
      expect(body.include?("設定済み")).to eq(true)
      expect(body.include?("Atlassian User")).to eq(true)
      expect(body.include?("acc-123")).to eq(true)
      expect(body.include?(OauthTestSupport::CLOUD_ID)).to eq(true)
      expect(body.include?("read:jira-work")).to eq(true)
      # Secret values never surface: client secret, tokens, raw state.
      expect(body.include?("atl-secret")).to eq(false)
      expect(body.include?("at-1")).to eq(false)
      expect(body.include?("rt-1")).to eq(false)
      ctx[:transport].assert_consumed!
    ensure
      OauthAdminSupport.uninstall_service
    end
  end
end

test("oauth index separates configured-but-unconnected from connected") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      http.get "/admin/oauth_connections"
      body = http.last_response.body
      # Configured env shows 設定済み, but without a verified connection
      # there is no 接続済み badge anywhere on the page.
      expect(body.scan("設定済み").size >= 2).to eq(true)
      expect(body.include?("接続済み")).to eq(false)
      expect(body.scan("未接続").size >= 2).to eq(true)
      expect(body.include?("連携開始")).to eq(true)
      expect(ctx[:transport].requests.size).to eq(0)
      ctx[:transport].assert_consumed!
    end
  end
end

test("oauth index shows connecting while an attempt is live") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      ctx[:auth].begin(provider: "microsoft", browser_session_id: "some-browser")
      http.get "/admin/oauth_connections"

      expect(http.last_response.status).to eq(200)
      expect(http.last_response.body.include?("接続中")).to eq(true)
      ctx[:transport].assert_consumed!
    end
  end
end

test("oauth index shows needs_reauth from a real refresh revocation") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      OauthTestSupport.connect(ctx, "atlassian")
      row = OauthConnection.find_by!(provider: "atlassian")
      row.update!(token_expires_at: 1.minute.ago)
      ctx[:transport].expect_error(
        :POST, "https://auth.atlassian.com/oauth/token",
        Aiconshell::Plugins::HttpError.new(
          status: 403, http_method: "POST", url: "https://auth.atlassian.com/oauth/token"
        )
      )
      begin
        ctx[:creds].access_token(ctx[:creds].binding_for("atlassian").to_h)
      rescue Aiconshell::Oauth::Error
        nil
      end
      expect(OauthConnection.find_by(provider: "atlassian").state).to eq("needs_reauth")

      http.get "/admin/oauth_connections"

      expect(http.last_response.status).to eq(200)
      body = http.last_response.body
      expect(body.include?("Atlassian（Jira Cloud）")).to eq(true)
      expect(body.include?("再認証必要")).to eq(true)
      expect(body.include?("接続の有効期限が切れました。再接続してください。")).to eq(true)
      expect(body.include?("Atlassian User")).to eq(true)
      expect(body.include?("acc-123")).to eq(true)
      expect(body.include?("解除")).to eq(true)
      ctx[:transport].assert_consumed!
    end
  end
end

test("oauth index shows a real initial failure without a connection") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      begun = ctx[:auth].begin(provider: "atlassian", browser_session_id: "browser-1")
      ctx[:transport].expect_json(:POST, "https://auth.atlassian.com/oauth/token", body: {
        "access_token" => "at-2", "refresh_token" => "rt-2",
        "expires_in" => 3600, "scope" => OauthTestSupport::ATLASSIAN_SCOPES, "token_type" => "Bearer"
      })
      ctx[:transport].expect_json(
        :GET, "https://api.atlassian.com/oauth/token/accessible-resources", body: [
          { "id" => OauthTestSupport::CLOUD_ID, "name" => "Test", "scopes" => ["read:jira-work"] }
        ]
      )
      begin
        ctx[:auth].callback(provider: "atlassian", state: begun["state"],
                            code: "auth-code-2", browser_session_id: "browser-1")
      rescue Aiconshell::Oauth::Error
        nil
      end
      expect(OauthConnection.find_by(provider: "atlassian").nil?).to eq(true)
      expect(OauthAuthAttempt.order(id: :desc).first.status).to eq("failed")

      http.get "/admin/oauth_connections"

      expect(http.last_response.status).to eq(200)
      body = http.last_response.body
      expect(body.include?("Atlassian（Jira Cloud）")).to eq(true)
      expect(body.include?("失敗")).to eq(true)
      expect(body.include?("直近の試行結果")).to eq(true)
      expect(body.include?("必要な権限が付与されませんでした")).to eq(true)
      expect(body.include?("接続済み")).to eq(false)
      ctx[:transport].assert_consumed!
    end
  end
end

test("oauth index keeps the healthy connection and shows a real reconnect failure separately") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      OauthTestSupport.connect(ctx, "microsoft")
      healthy_principal = OauthConnection.find_by!(provider: "microsoft").external_principal

      begun = ctx[:auth].begin(provider: "microsoft", browser_session_id: "browser-2")
      ctx[:transport].expect_json(
        :POST, "https://login.microsoftonline.com/test-tenant/oauth2/v2.0/token", body: {
          "access_token" => "ms-at-2", "refresh_token" => "ms-rt-2",
          "expires_in" => 3600, "scope" => "User.Read", "token_type" => "Bearer"
        }
      )
      ctx[:transport].expect_json(:GET, "https://graph.microsoft.com/v1.0/me", body: {
        "id" => "user-oid-1", "displayName" => "MS User", "userPrincipalName" => "u@example.test"
      })
      begin
        ctx[:auth].callback(provider: "microsoft", state: begun["state"],
                            code: "auth-code-2", browser_session_id: "browser-2")
      rescue Aiconshell::Oauth::Error
        nil
      end

      kept = OauthConnection.find_by!(provider: "microsoft")
      expect(kept.state).to eq("connected")
      expect(kept.external_principal).to eq(healthy_principal)
      expect(OauthAuthAttempt.order(id: :desc).first.status).to eq("failed")

      http.get "/admin/oauth_connections"

      expect(http.last_response.status).to eq(200)
      body = http.last_response.body
      expect(body.include?("Microsoft（Teams / Graph）")).to eq(true)
      expect(body.include?("接続済み")).to eq(true)
      expect(body.include?("MS User")).to eq(true)
      expect(body.include?(healthy_principal)).to eq(true)
      expect(body.include?("直近の試行結果")).to eq(true)
      expect(body.include?("現在の接続はそのまま残ります")).to eq(true)
      expect(body.include?("解除")).to eq(true)
      ctx[:transport].assert_consumed!
    end
  end
end

test("oauth index preserves identity and disconnect while a reconnect attempt is live") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      OauthTestSupport.connect(ctx, "microsoft")
      ctx[:auth].begin(provider: "microsoft", browser_session_id: "browser-live")

      http.get "/admin/oauth_connections"

      expect(http.last_response.status).to eq(200)
      body = http.last_response.body
      expect(body.include?("Microsoft（Teams / Graph）")).to eq(true)
      expect(body.include?("接続済み")).to eq(true)
      expect(body.include?("接続中")).to eq(true)
      expect(body.include?("MS User")).to eq(true)
      expect(body.include?("user-oid-1")).to eq(true)
      expect(body.include?("disconnect?provider=microsoft")).to eq(true)
      ctx[:transport].assert_consumed!
    end
  end
end

test("oauth index offers disconnect for a live first attempt") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      ctx[:auth].begin(provider: "atlassian", browser_session_id: "browser-first")

      http.get "/admin/oauth_connections"

      expect(http.last_response.status).to eq(200)
      body = http.last_response.body
      expect(body.include?("Atlassian（Jira Cloud）")).to eq(true)
      expect(body.include?("接続中")).to eq(true)
      expect(body.include?("disconnect?provider=atlassian")).to eq(true)

      http.post "/admin/oauth_connections/disconnect", { provider: "atlassian" }
      expect(http.last_response.status).to eq(302)
      expect(OauthAuthAttempt.order(id: :desc).first.status).to eq("expired")
      expect(OauthConnection.find_by(provider: "atlassian").state).to eq("disconnected")
      ctx[:transport].assert_consumed!
    end
  end
end

test("disconnect of a live attempt works when configuration is missing") do |http:|
  AdminTestSupport.as_admin(http) do
    ctx = OauthAdminSupport.install_service
    begin
      ctx[:auth].begin(provider: "microsoft", browser_session_id: "browser-live-missing")
      expect(OauthAuthAttempt.active.where(provider: "microsoft").count).to eq(1)

      OauthAdminSupport.uninstall_service
      OauthAdminSupport.install_service(env: {})

      http.get "/admin/oauth_connections"
      expect(http.last_response.status).to eq(200)
      expect(http.last_response.body.include?("disconnect?provider=microsoft")).to eq(true)

      http.post "/admin/oauth_connections/disconnect", { provider: "microsoft" }
      expect(http.last_response.status).to eq(302)
      expect(OauthAuthAttempt.active.where(provider: "microsoft").count).to eq(0)
      expect(OauthConnection.find_by(provider: "microsoft").state).to eq("disconnected")
    ensure
      OauthAdminSupport.uninstall_service
    end
  end
end

test("disconnect works when configuration is missing") do |http:|
  AdminTestSupport.as_admin(http) do
    ctx = OauthAdminSupport.install_service
    begin
      OauthTestSupport.connect(ctx, "atlassian")
      expect(OauthConnection.find_by(provider: "atlassian").state).to eq("connected")

      OauthAdminSupport.uninstall_service
      OauthAdminSupport.install_service(env: {})
      http.post "/admin/oauth_connections/disconnect", { provider: "atlassian" }
      expect(http.last_response.status).to eq(302)
      expect(OauthConnection.find_by(provider: "atlassian").state).to eq("disconnected")
      http.follow_redirect!
      expect(http.last_response.body.include?("未設定")).to eq(true)
      expect(http.last_response.body.include?("disconnect?provider=atlassian")).to eq(false)
    ensure
      OauthAdminSupport.uninstall_service
    end
  end
end

test("connect POST starts an attempt and redirects to the fixed provider") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      http.post "/admin/oauth_connections/connect", { provider: "atlassian" }

      expect(http.last_response.status).to eq(302)
      location = http.last_response.headers["Location"]
      expect(location.start_with?("https://auth.atlassian.com/authorize?")).to eq(true)
      expect(location.include?("state=")).to eq(true)
      # The 302 itself carries no-store and no-referrer.
      expect(http.last_response.headers["Cache-Control"]).to eq("no-store")
      expect(http.last_response.headers["Referrer-Policy"]).to eq("no-referrer")
      attempt = OauthAuthAttempt.last
      expect(attempt.provider).to eq("atlassian")
      expect(attempt.status).to eq("pending")
      ctx[:transport].assert_consumed!
    end
  end
end

test("connect rejects unknown, array, and missing providers without rows") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      http.post "/admin/oauth_connections/connect", { provider: "evil" }
      expect(http.last_response.status).to eq(302)
      expect(http.last_response.body.include?("evil")).to eq(false)

      http.post "/admin/oauth_connections/connect", { "provider" => %w[atlassian microsoft] }
      expect(http.last_response.status).to eq(302)

      http.post "/admin/oauth_connections/connect", {}
      expect(http.last_response.status).to eq(302)

      expect(OauthAuthAttempt.count).to eq(0)
      expect(http.last_response.headers["Location"]).to eq("http://app.test/admin/oauth_connections")
      ctx[:transport].assert_consumed!
    end
  end
end

test("unconfigured connect fails safe without rows") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service(env: {}) do |ctx|
      http.post "/admin/oauth_connections/connect", { provider: "atlassian" }

      expect(http.last_response.status).to eq(302)
      expect(OauthAuthAttempt.count).to eq(0)
      expect(OauthConnection.count).to eq(0)
      http.follow_redirect!
      expect(http.last_response.body.include?("設定がありません")).to eq(true)
      ctx[:transport].assert_consumed!
    end
  end
end

test("CSRF: connect and disconnect without token are rejected") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      AdminTestSupport.with_forgery_protection do
        http.post "/admin/oauth_connections/connect", { provider: "atlassian" }
        expect(http.last_response.status).to eq(422)
        expect(OauthAuthAttempt.count).to eq(0)

        http.post "/admin/oauth_connections/disconnect", { provider: "atlassian" }
        expect(http.last_response.status).to eq(422)
        ctx[:transport].assert_consumed!
      end
    end
  end
end

test("CSRF: connect with form token succeeds") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      AdminTestSupport.with_forgery_protection do
        http.get "/admin/oauth_connections"
        form = http.last_response.body[
          %r{<form[^>]*action="/admin/oauth_connections/connect\?provider=atlassian"[^>]*>.*?</form>}m, 0
        ]
        expect(form.nil?).to eq(false)
        token = form[/name="authenticity_token" value="([^"]+)"/, 1]
        expect(token.nil?).to eq(false)

        http.post "/admin/oauth_connections/connect?provider=atlassian",
          { authenticity_token: token }
        expect(http.last_response.status).to eq(302)
        expect(OauthAuthAttempt.where(provider: "atlassian").count).to eq(1)
        ctx[:transport].assert_consumed!
      end
    end
  end
end

test("disconnect clears tokens, bumps generation, and explains provider scope") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      connection = OauthTestSupport.connect(ctx, "atlassian")
      expect(connection.generation).to eq(1)

      http.post "/admin/oauth_connections/disconnect", { provider: "atlassian" }
      expect(http.last_response.status).to eq(302)
      http.follow_redirect!
      body = http.last_response.body
      expect(body.include?("プロバイダー側の同意取り消しは別途")).to eq(true)
      expect(body.include?("未接続")).to eq(true)

      row = OauthConnection.find_by(provider: "atlassian")
      expect(row.state).to eq("disconnected")
      expect(row.generation).to eq(2)
      expect(row.encrypted_access_token.nil?).to eq(true)
      expect(row.encrypted_refresh_token.nil?).to eq(true)
      ctx[:transport].assert_consumed!
    end
  end
end

test("oauth pages are reachable from nav and plugins diagnosis") do |http:|
  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      http.get "/admin/tasks"
      expect(http.last_response.body.include?("OAuth連携")).to eq(true)

      http.get "/admin/plugins"
      body = http.last_response.body
      expect(body.include?("OAuth連携")).to eq(true)
      expect(body.include?("/admin/oauth_connections")).to eq(true)
      # The existing plugin display is intact.
      expect(body.include?("プラグイン設定状況")).to eq(true)
      ctx[:transport].assert_consumed!
    end
  end
end

test("ai connections page still renders without oauth interference") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/ai_connections"
    expect(http.last_response.status).to eq(200)
    expect(http.last_response.body.include?("AIアカウント連携")).to eq(true)
  end
end
