# frozen_string_literal: true

require "db_helper"
require_relative "ai_auth_test_support"

# Cross-connection visibility without the transactional `db` fixture: rows
# are committed so a raw PG connection (another web/worker process) can
# change them, and the worker callbacks must observe those changes even
# with the query cache enabled.
def other_pg_connection
  config = ActiveRecord::Base.connection_db_config.configuration_hash
  require "pg" unless defined?(PG)
  PG.connect(
    host: config[:host] || "localhost",
    port: config[:port] || 5432,
    dbname: config[:database],
    user: config[:username] || config[:user],
    password: config[:password]
  )
end

def with_committed_session(provider: "claude", role: "control", operation: "login")
  service = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
  session = operation == "login" ?
    service.request_login(provider: provider, worker_role: role) :
    service.request_status(provider: provider, worker_role: role)
  yield session
ensure
  uuid = session&.uuid
  if uuid
    AiAuthSession.where(uuid: uuid).delete_all
    SolidQueue::Job.where(class_name: "AiAuthJob").each do |job|
      args = job.arguments["arguments"] rescue nil
      job.destroy if args&.first == uuid
    end
  end
  AiConnection.where(provider: provider, worker_role: role).delete_all
end

test("cancel from another connection is observed despite query cache") do
  with_worker_role("control") do
    with_committed_session do |session|
      token = SecureRandom.uuid
      session.update_columns(status: "running", claim_token: token,
                             claimed_at: Time.current, heartbeat_at: Time.current,
                             updated_at: Time.current)

      service = AiAuth::WorkerService.new(
        runner: AiAuthTestSupport::FakeAuthRunner.immediate,
        event_sink: WorkflowFakes::FakeEventSink.new
      )
      cancelled = service.send(:cancelled_callback, session.id, token)

      ActiveRecord::Base.connection.enable_query_cache!
      ActiveRecord::Base.connection.clear_query_cache
      begin
        expect(cancelled.call).to eq(false)

        other = other_pg_connection
        begin
          other.exec_params("UPDATE ai_auth_sessions SET cancel_requested = TRUE WHERE id = $1", [session.id])
        ensure
          other.close
        end

        expect(cancelled.call).to eq(true)
      ensure
        ActiveRecord::Base.connection.clear_query_cache
        ActiveRecord::Base.connection.disable_query_cache!
      end
    end
  end
end

test("code input from another connection is consumed exactly once") do
  with_worker_role("control") do
    with_committed_session do |session|
      token = SecureRandom.uuid
      challenge = AiAuth::SecretBox.default.encrypt(
        { "verification_uri" => "https://example.invalid/auth", "user_code" => nil, "input_required" => true }
      )
      session.update_columns(status: "waiting", claim_token: token,
                             claimed_at: Time.current, heartbeat_at: Time.current,
                             encrypted_challenge: challenge,
                             challenge_updated_at: Time.current,
                             updated_at: Time.current)

      service = AiAuth::WorkerService.new(
        runner: AiAuthTestSupport::FakeAuthRunner.immediate,
        event_sink: WorkflowFakes::FakeEventSink.new
      )
      input_cb = service.send(:input_callback, session.id, token)

      ActiveRecord::Base.connection.enable_query_cache!
      ActiveRecord::Base.connection.clear_query_cache
      begin
        expect(input_cb.call).to eq(nil)

        ciphertext = AiAuth::SecretBox.default.encrypt("other-conn-code#s1")
        other = other_pg_connection
        begin
          other.exec_params(
            "UPDATE ai_auth_sessions SET encrypted_input_code = $1, input_updated_at = NOW(), input_submitted_at = NOW() WHERE id = $2",
            [ciphertext, session.id]
          )
        ensure
          other.close
        end

        expect(input_cb.call).to eq("other-conn-code#s1")
        expect(input_cb.call).to eq(nil)
        expect(session.reload.input_submitted_at.nil?).to eq(false)
      ensure
        ActiveRecord::Base.connection.clear_query_cache
        ActiveRecord::Base.connection.disable_query_cache!
      end
    end
  end
end
