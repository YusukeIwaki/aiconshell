# frozen_string_literal: true

require "db_helper"
require_relative "oauth_test_support"
require_relative "oauth_admin_support"
require_relative "../admin/support/admin_test_support"

# End-to-end OAuth operator flow through the real controllers, real
# browser session, and real PostgreSQL (issue #23). Only the provider
# HTTP boundary is scripted. The final test proves request, redirect,
# and error logging never retain code/state or authorization URLs.
module OauthAdminFlowHelper
  module_function

  def connect_headers(http)
    http.header "Host", AdminTestSupport::HOST
    http.header "User-Agent", AdminTestSupport::MODERN_UA
    http.basic_authorize AdminTestSupport::USERNAME, AdminTestSupport::PASSWORD
  end

  def with_admin_env
    AdminTestSupport.with_env(AdminTestSupport::USERNAME, AdminTestSupport::PASSWORD) { yield }
  ensure
    Admin::OauthStatus.reset!
  end

  # Full browser round trip: admin begin POST -> provider authorize
  # redirect -> public callback GET -> query-free admin page. Returns
  # [location, state]; callers assert statuses themselves (Smartest
  # expectations only run inside test blocks, not in helpers).
  def round_trip(http, ctx, provider, code: "auth-code-1", error: nil, extra: {})
    http.post "/admin/oauth_connections/connect", { provider: provider }
    begin_status = http.last_response.status
    location = http.last_response.headers["Location"]
    state = OauthAdminSupport.state_from_location(location)

    if provider.to_s == "atlassian"
      OauthTestSupport.script_atlassian_callback(ctx[:transport])
    else
      OauthTestSupport.script_microsoft_callback(ctx[:transport])
    end
    query = { state: state, code: code, error: error }.merge(extra).compact
    http.get "/oauth/#{provider}/callback", query
    [begin_status, location, state]
  end
end

test("atlassian round trip connects through real controllers and session") do |http:|
  tasks_before = Task.count
  runs_before = TaskRun.count

  OauthAdminFlowHelper.with_admin_env do
    OauthAdminSupport.with_service do |ctx|
      OauthAdminFlowHelper.connect_headers(http)

      begin_status, location, = OauthAdminFlowHelper.round_trip(http, ctx, "atlassian")
      expect(begin_status).to eq(302)
      expect(location.start_with?("https://auth.atlassian.com/authorize?")).to eq(true)

      # The provider callback lands on the query-free admin page.
      expect(http.last_response.status).to eq(302)
      expect(http.last_response.headers["Location"]).to eq("http://app.test/admin/oauth_connections")
      expect(http.last_response.headers["Referrer-Policy"]).to eq("no-referrer")
      http.follow_redirect!
      expect(http.last_response.status).to eq(200)
      body = http.last_response.body
      expect(body.include?("接続しました")).to eq(true)
      expect(body.include?("接続済み")).to eq(true)
      expect(body.include?("Atlassian User")).to eq(true)

      connection = OauthConnection.find_by(provider: "atlassian")
      expect(connection.state).to eq("connected")
      expect(connection.generation).to eq(1)
      expect(OauthAuthAttempt.last.status).to eq("succeeded")

      # No business records or jobs: the flow only touches OAuth rows.
      expect(Task.count).to eq(tasks_before)
      expect(TaskRun.count).to eq(runs_before)
      expect(ctx[:sink].kinds.all? { |kind| kind.start_with?("oauth.") }).to eq(true)
      ctx[:transport].assert_consumed!
    end
  end
end

test("microsoft round trip consumes PKCE through the public callback") do |http:|
  OauthAdminFlowHelper.with_admin_env do
    OauthAdminSupport.with_service do |ctx|
      OauthAdminFlowHelper.connect_headers(http)

      begin_status, location, = OauthAdminFlowHelper.round_trip(http, ctx, "microsoft")
      expect(begin_status).to eq(302)
      expect(location).to match(%r{\Ahttps://login\.microsoftonline\.com/test-tenant/oauth2/v2\.0/authorize\?})
      expect(http.last_response.status).to eq(302)
      http.follow_redirect!
      expect(http.last_response.body.include?("接続済み")).to eq(true)

      connection = OauthConnection.find_by(provider: "microsoft")
      expect(connection.state).to eq("connected")
      expect(connection.external_principal).to eq("user-oid-1")
      expect(connection.tenant_id).to eq("test-tenant")
      ctx[:transport].assert_consumed!
    end
  end
end

test("callback works without admin credentials but stays session-bound") do |http:|
  OauthAdminFlowHelper.with_admin_env do
    OauthAdminSupport.with_service do |ctx|
      OauthAdminFlowHelper.connect_headers(http)
      http.post "/admin/oauth_connections/connect", { provider: "atlassian" }
      state = OauthAdminSupport.state_from_location(http.last_response.headers["Location"])

      # The provider cannot supply Basic credentials: drop them. The
      # browser session cookie is what binds the callback.
      http.header "Authorization", ""
      OauthTestSupport.script_atlassian_callback(ctx[:transport])
      http.get "/oauth/atlassian/callback", { state: state, code: "auth-code-1" }
      expect(http.last_response.status).to eq(302)

      http.basic_authorize AdminTestSupport::USERNAME, AdminTestSupport::PASSWORD
      http.follow_redirect!
      expect(http.last_response.body.include?("接続済み")).to eq(true)
      ctx[:transport].assert_consumed!
    end
  end
end

test("callback from another browser session is rejected without consuming") do |http:|
  OauthAdminFlowHelper.with_admin_env do
    OauthAdminSupport.with_service do |ctx|
      OauthAdminFlowHelper.connect_headers(http)
      http.post "/admin/oauth_connections/connect", { provider: "atlassian" }
      state = OauthAdminSupport.state_from_location(http.last_response.headers["Location"])

      http.clear_cookies
      http.get "/oauth/atlassian/callback", { state: state, code: "auth-code-1" }
      expect(http.last_response.status).to eq(302)
      http.follow_redirect!
      expect(http.last_response.body.include?("認証の検証に失敗しました")).to eq(true)
      expect(OauthConnection.count).to eq(0)
      expect(OauthAuthAttempt.last.status).to eq("pending")
      expect(ctx[:transport].requests.size).to eq(0)
      ctx[:transport].assert_consumed!
    end
  end
end

test("double callback through HTTP is rejected") do |http:|
  OauthAdminFlowHelper.with_admin_env do
    OauthAdminSupport.with_service do |ctx|
      OauthAdminFlowHelper.connect_headers(http)
      begin_status, _location, state = OauthAdminFlowHelper.round_trip(http, ctx, "atlassian")
      expect(begin_status).to eq(302)
      expect(OauthConnection.find_by(provider: "atlassian").state).to eq("connected")

      http.get "/oauth/atlassian/callback", { state: state, code: "auth-code-1" }
      expect(http.last_response.status).to eq(302)
      http.follow_redirect!
      expect(http.last_response.body.include?("接続済み")).to eq(true)
      expect(OauthConnection.find_by(provider: "atlassian").generation).to eq(1)
      expect(ctx[:transport].requests_to("https://auth.atlassian.com/oauth/token", method: :POST).size).to eq(1)
      ctx[:transport].assert_consumed!
    end
  end
end

test("denied consent keeps the healthy connection and hides descriptions") do |http:|
  OauthAdminFlowHelper.with_admin_env do
    OauthAdminSupport.with_service do |ctx|
      OauthAdminFlowHelper.connect_headers(http)
      OauthTestSupport.connect(ctx, "microsoft", session: "owner-session")

      http.post "/admin/oauth_connections/connect", { provider: "microsoft" }
      state = OauthAdminSupport.state_from_location(http.last_response.headers["Location"])
      http.get "/oauth/microsoft/callback",
        { state: state, error: "access_denied", error_description: "desc-LOGPROBE-end-user-denied" }
      expect(http.last_response.status).to eq(302)
      http.follow_redirect!
      body = http.last_response.body
      expect(body.include?("同意が拒否")).to eq(true)
      expect(body.include?("desc-LOGPROBE-end-user-denied")).to eq(false)

      kept = OauthConnection.find_by(provider: "microsoft")
      expect(kept.state).to eq("connected")
      expect(kept.external_principal).to eq("user-oid-1")
      ctx[:transport].assert_consumed!
    end
  end
end

test("array, hash, and oversized callback params are rejected safely") do |http:|
  OauthAdminFlowHelper.with_admin_env do
    OauthAdminSupport.with_service do |ctx|
      OauthAdminFlowHelper.connect_headers(http)

      http.get "/oauth/atlassian/callback", { "state" => %w[a b], "code" => "x" }
      expect(http.last_response.status).to eq(302)

      http.get "/oauth/atlassian/callback", { "state" => { "x" => "y" }, "code" => "x" }
      expect(http.last_response.status).to eq(302)

      http.get "/oauth/atlassian/callback", { "state" => "s" * 5000, "code" => "c" * 5000 }
      expect(http.last_response.status).to eq(302)

      http.follow_redirect!
      expect(http.last_response.status).to eq(200)
      expect(OauthConnection.count).to eq(0)
      expect(OauthAuthAttempt.count).to eq(0)
      expect(ctx[:transport].requests.size).to eq(0)
      ctx[:transport].assert_consumed!
    end
  end
end

test("disconnect via HTTP stops reuse and old callbacks cannot resurrect") do |http:|
  OauthAdminFlowHelper.with_admin_env do
    OauthAdminSupport.with_service do |ctx|
      OauthAdminFlowHelper.connect_headers(http)
      begin_status, _, _ = OauthAdminFlowHelper.round_trip(http, ctx, "atlassian")
      expect(begin_status).to eq(302)
      expect(OauthConnection.find_by(provider: "atlassian").generation).to eq(1)

      http.post "/admin/oauth_connections/connect", { provider: "atlassian" }
      stale_state = OauthAdminSupport.state_from_location(http.last_response.headers["Location"])

      http.post "/admin/oauth_connections/disconnect", { provider: "atlassian" }
      expect(http.last_response.status).to eq(302)
      expect(OauthConnection.find_by(provider: "atlassian").state).to eq("disconnected")

      # No script: generation fencing rejects the stale callback before
      # any HTTP is attempted.
      http.get "/oauth/atlassian/callback", { state: stale_state, code: "auth-code-9" }
      expect(http.last_response.status).to eq(302)
      http.follow_redirect!
      # The disconnected attempt is already terminal, so the stale
      # callback is rejected as a mismatch and nothing is resurrected.
      expect(http.last_response.body.include?("認証の検証に失敗しました")).to eq(true)
      expect(OauthConnection.find_by(provider: "atlassian").state).to eq("disconnected")
      expect(OauthConnection.find_by(provider: "atlassian").generation).to eq(2)
      expect(ctx[:transport].requests.size).to eq(3)
      ctx[:transport].assert_consumed!
    end
  end
end

test("request, redirect, and error logs never retain code, state, or authorization URLs") do |http:|
  io = StringIO.new
  sink = Logger.new(io)
  Rails.logger.broadcast_to(sink)

  markers = []
  OauthAdminFlowHelper.with_admin_env do
    env = OauthTestSupport.test_env.merge(
      "OAUTH_ATLASSIAN_CLIENT_SECRET" => "atl-secret-LOGPROBE-7q2"
    )
    OauthAdminSupport.with_service(env: env) do |ctx|
      OauthAdminFlowHelper.connect_headers(http)

      # Successful round trip with marked secrets.
      http.post "/admin/oauth_connections/connect", { provider: "atlassian" }
      location = http.last_response.headers["Location"]
      state = OauthAdminSupport.state_from_location(location)
      markers << state
      markers << "auth-code-LOGPROBE-7q2"
      OauthTestSupport.script_atlassian_callback(
        ctx[:transport], access: "at-LOGPROBE-7q2", refresh: "rt-LOGPROBE-7q2"
      )
      markers << "at-LOGPROBE-7q2"
      markers << "rt-LOGPROBE-7q2"
      markers << "atl-secret-LOGPROBE-7q2"
      http.get "/oauth/atlassian/callback",
        { state: state, code: "auth-code-LOGPROBE-7q2" }
      http.follow_redirect!

      # Failing paths: wrong state, denied consent with a description
      # probe, and a CSRF error page.
      http.get "/oauth/atlassian/callback", { state: "bogus-state-LOGPROBE", code: "bogus" }
      markers << "bogus-state-LOGPROBE"
      http.post "/admin/oauth_connections/connect", { provider: "microsoft" }
      ms_location = http.last_response.headers["Location"]
      ms_state = OauthAdminSupport.state_from_location(ms_location)
      markers << ms_state
      # The live PKCE challenge/verifier values (not just their names)
      # must never reach the logs. The verifier is decrypted here with
      # the test secret store before the denial clears it.
      ms_query = URI.decode_www_form(URI.parse(ms_location).query.to_s).to_h
      markers << ms_query["code_challenge"].to_s
      ms_verifier = ctx[:store].decrypt(OauthAuthAttempt.last.encrypted_code_verifier)
      markers << ms_verifier.to_s
      # The value markers really exist (non-vacuous proof).
      expect(ms_query["code_challenge"].to_s.empty?).to eq(false)
      expect(ms_verifier.to_s.empty?).to eq(false)
      http.get "/oauth/microsoft/callback",
        { state: ms_state, error: "access_denied", error_description: "desc-LOGPROBE-7q2" }
      markers << "desc-LOGPROBE-7q2"

      AdminTestSupport.with_forgery_protection do
        http.post "/admin/oauth_connections/disconnect", { provider: "atlassian" }
        expect(http.last_response.status).to eq(422)
      end

      http.post "/admin/oauth_connections/disconnect", { provider: "atlassian" }
      ctx[:transport].assert_consumed!
    end
  end

  logs = io.string
  # The capture window really saw Rails request and redirect logging.
  expect(logs.include?("Started")).to eq(true)
  expect(logs.include?("Completed")).to eq(true)
  expect(logs.include?("Redirected to http://app.test/admin/oauth_connections")).to eq(true)
  expect(logs.include?("[FILTERED]")).to eq(true)

  markers.each do |marker|
    next if marker.to_s.empty?

    expect(logs.include?(marker)).to eq(false)
  end
  # The authorize redirect (state/code_challenge URL) is never logged,
  # even though redirect logging itself is active (proven above).
  expect(logs.include?("auth.atlassian.com/authorize")).to eq(false)
  expect(logs.include?("login.microsoftonline.com/test-tenant/oauth2/v2.0/authorize")).to eq(false)
  expect(logs.include?("code_challenge")).to eq(false)
  # "code_verifier" alone also matches the SQL column name
  # "encrypted_code_verifier" (schema, always logged); the live verifier
  # *value* is covered by the markers above, and its ciphertext bind is
  # [FILTERED] in the query log.
  # Filtered parameter *names* (e.g. "error_description"=>"[FILTERED]")
  # stay in the log schema; their *values* must not. The desc-LOGPROBE
  # marker above proves the value never appears.
end
