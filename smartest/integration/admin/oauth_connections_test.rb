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

test("oauth index distinguishes needs_reauth and failed") do |http:|
  OauthConnection.create!(provider: "atlassian", state: "needs_reauth",
                          error_code: "invalid_grant", generation: 3,
                          external_principal: "acc-123", display_name: "A User",
                          cloud_id: OauthTestSupport::CLOUD_ID,
                          granted_scopes: "read:jira-work")
  OauthConnection.create!(provider: "microsoft", state: "failed",
                          error_code: "unexpected_response", generation: 1)

  AdminTestSupport.as_admin(http) do
    OauthAdminSupport.with_service do |ctx|
      http.get "/admin/oauth_connections"

      expect(http.last_response.status).to eq(200)
      body = http.last_response.body
      expect(body.include?("再認証必要")).to eq(true)
      expect(body.include?("失敗")).to eq(true)
      expect(body.include?("接続の有効期限が切れました。再接続してください。")).to eq(true)
      expect(body.include?("A User")).to eq(true)
      ctx[:transport].assert_consumed!
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
