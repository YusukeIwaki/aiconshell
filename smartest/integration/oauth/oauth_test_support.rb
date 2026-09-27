# frozen_string_literal: true

require_relative "../../support/boundary_fixtures"

# Shared scaffolding for OAuth foundation integration tests (issue #22).
# Real Rails services + real PostgreSQL; only the HTTP boundary (and the
# clock where noted) is replaced with strict scripted fixtures.
module OauthTestSupport
  CLOUD_ID = "11111111-2222-3333-4444-555555555555"
  ATLASSIAN_SCOPES = "offline_access read:jira-work write:jira-work read:jira-user"
  MICROSOFT_SCOPES = "offline_access User.Read ChannelMessage.Read.All ChannelMessage.Send Chat.Read ChatMessage.Send"

  module_function

  def test_env(overrides = {})
    {
      "OAUTH_ATLASSIAN_CLIENT_ID" => "atl-client",
      "OAUTH_ATLASSIAN_CLIENT_SECRET" => "atl-secret",
      "OAUTH_ATLASSIAN_CLOUD_ID" => CLOUD_ID,
      "OAUTH_ATLASSIAN_REDIRECT_URI" => "https://app.example.test/oauth/atlassian/callback",
      "OAUTH_MICROSOFT_CLIENT_ID" => "ms-client",
      "OAUTH_MICROSOFT_CLIENT_SECRET" => "ms-secret",
      "OAUTH_MICROSOFT_TENANT_ID" => "test-tenant",
      "OAUTH_MICROSOFT_REDIRECT_URI" => "https://app.example.test/oauth/microsoft/callback"
    }.merge(overrides)
  end

  def secret_store
    Oauth::SecretStore.new(key: SecureRandom.bytes(32))
  end

  def services(env: test_env, transport: nil, sink: nil, store: nil)
    transport ||= BoundaryFixtures::HttpTransport.new
    sink ||= WorkflowFakes::FakeEventSink.new
    store ||= secret_store
    auth = Oauth::AuthService.new(env: env, transport: transport, clock: Time,
                                  secret_store: store, event_sink: sink)
    tokens = Oauth::TokenService.new(env: env, transport: transport, clock: Time,
                                     secret_store: store, event_sink: sink)
    creds = Oauth::CredentialProvider.new(env: env, transport: transport, clock: Time,
                                          secret_store: store, event_sink: sink)
    { auth: auth, tokens: tokens, creds: creds, transport: transport, sink: sink, store: store, env: env }
  end

  def script_atlassian_callback(transport, access: "at-1", refresh: "rt-1",
                                principal: "acc-123", display: "Atlassian User")
    transport.expect_json(:POST, "https://auth.atlassian.com/oauth/token", body: {
      "access_token" => access, "refresh_token" => refresh,
      "expires_in" => 3600, "scope" => ATLASSIAN_SCOPES, "token_type" => "Bearer"
    })
    transport.expect_json(:GET, "https://api.atlassian.com/oauth/token/accessible-resources", body: [
      { "id" => CLOUD_ID, "name" => "Test",
        "scopes" => %w[offline_access read:jira-work write:jira-work read:jira-user],
        "avatarUrl" => "https://example.test/b.png" }
    ])
    transport.expect_json(:GET, "https://api.atlassian.com/ex/jira/#{CLOUD_ID}/rest/api/3/myself", body: {
      "accountId" => principal, "displayName" => display
    })
  end

  def script_microsoft_callback(transport, access: "ms-at-1", refresh: "ms-rt-1",
                                principal: "user-oid-1", display: "MS User")
    transport.expect_json(:POST, "https://login.microsoftonline.com/test-tenant/oauth2/v2.0/token", body: {
      "access_token" => access, "refresh_token" => refresh,
      "expires_in" => 3600, "scope" => MICROSOFT_SCOPES, "token_type" => "Bearer"
    })
    transport.expect_json(:GET, "https://graph.microsoft.com/v1.0/me", body: {
      "id" => principal, "displayName" => display, "userPrincipalName" => "u@example.test"
    })
  end

  # Full begin + callback round trip for one provider. Returns the connection.
  def connect(ctx, provider, session: "browser-session-1", **script_opts)
    begun = ctx[:auth].begin(provider: provider, browser_session_id: session)
    if provider.to_s == "atlassian"
      script_atlassian_callback(ctx[:transport], **script_opts)
    else
      script_microsoft_callback(ctx[:transport], **script_opts)
    end
    ctx[:auth].callback(provider: provider, state: begun["state"],
                        code: "auth-code-1", browser_session_id: session)
  end

  def binding_for(ctx, provider)
    ctx[:creds].binding_for(provider)
  end

  # Thread-safe injectable clock for race tests. Services read it fresh
  # after every lock, so advancing it mid-wait proves the TTL/lease
  # rechecks instead of trusting a timestamp fixed before the wait.
  class ManualClock
    def initialize(now)
      @mutex = Mutex.new
      @now = now
    end

    def now
      @mutex.synchronize { @now }
    end
    alias current now

    def advance(seconds)
      @mutex.synchronize { @now += seconds }
    end
  end

  # Bounded poll proving a real PostgreSQL lock wait: waiter_pid must be
  # blocked by holder_pid in pg_blocking_pids, not merely alive or
  # sleeping. Raises on timeout instead of hanging the suite.
  def wait_for_lock_waiter(waiter_pid, holder_pid, timeout: 15)
    waiter_pid = Integer(waiter_pid)
    holder_pid = Integer(holder_pid)
    raise "race requires independent sessions" if waiter_pid == holder_pid

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    ActiveRecord::Base.connection_pool.with_connection do |observer|
      loop do
        blocked = observer.select_value(
          "SELECT #{holder_pid} = ANY(pg_blocking_pids(#{waiter_pid}))"
        )
        return if blocked
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise "session #{waiter_pid} never blocked on #{holder_pid}"
        end
        sleep 0.01
      end
    end
  end
end
