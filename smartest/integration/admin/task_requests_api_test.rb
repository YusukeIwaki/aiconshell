# frozen_string_literal: true

require "db_helper"
require "json"
require "logger"
require "rack/mock"
require "securerandom"
require "stringio"
require_relative "support/admin_test_support"
require_relative "support/task_request_test_support"
require_relative "../../fixtures/workflow_fakes"

test("API rejects missing, wrong, Basic, and cookie auth and fails closed") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    TaskRequestTestSupport.api_get(http, SecureRandom.uuid, token: nil)
    expect(http.last_response.status).to eq(401)
    TaskRequestTestSupport.api_get(http, SecureRandom.uuid, token: "wrong-token")
    expect(http.last_response.status).to eq(401)
    http.header "Host", AdminTestSupport::HOST
    http.header "Authorization", "Basic #{["u:p"].pack("m0")}"
    http.get "/api/admin/task_requests/#{SecureRandom.uuid}"
    expect(http.last_response.status).to eq(401)
    http.header "Cookie", "session=xyz"
    http.header "Authorization", nil
    http.get "/api/admin/task_requests/#{SecureRandom.uuid}"
    expect(http.last_response.status).to eq(401)
  end
  TaskRequestTestSupport.with_api_token("") do
    TaskRequestTestSupport.api_get(http, SecureRandom.uuid, token: TaskRequestTestSupport::API_TOKEN)
    expect(http.last_response.status).to eq(401)
  end
  TaskRequestTestSupport.with_api_token(nil) do
    TaskRequestTestSupport.api_post(http, { title: "t", description: "d" },
      key: "k1", token: TaskRequestTestSupport::API_TOKEN)
    expect(http.last_response.status).to eq(401)
  end
end

test("API accepts JSON only and reports malformed bodies") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    TaskRequestTestSupport.api_post(http, { title: "t", description: "d" }, key: "json-only-1",
      content_type: "application/x-www-form-urlencoded")
    expect(http.last_response.status).to eq(400)
    expect(JSON.parse(http.last_response.body)["error"]).to eq("json_only")
    TaskRequestTestSupport.api_post(http, "{not-json", key: "json-only-2")
    expect(http.last_response.status).to eq(400)
    expect(JSON.parse(http.last_response.body)["error"]).to eq("malformed_json")
    TaskRequestTestSupport.api_post(http, "", key: "json-only-3")
    expect(http.last_response.status).to eq(400)
    expect(TaskRequest.count).to eq(0)
  end
end

test("API rejects wrong input content type consistently") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    [
      "text/plain",
      "application/x-www-form-urlencoded",
      "multipart/form-data; boundary=xyz",
      ""
    ].each_with_index do |ctype, index|
      TaskRequestTestSupport.api_post(http, '{"title":"t","description":"d"}',
        key: "ctype-#{index}-#{SecureRandom.hex(4)}", content_type: ctype)
      expect(http.last_response.status).to eq(400)
      expect(JSON.parse(http.last_response.body)["error"]).to eq("json_only")
    end
    TaskRequestTestSupport.api_post(http, { title: "charset-ok", description: "d" },
      key: "ctype-charset-#{SecureRandom.hex(4)}", content_type: "application/json; charset=utf-8")
    expect(http.last_response.status).to eq(202)
    expect(TaskRequest.count).to eq(1)
  end
end

test("API rejects unknown fields and invalid payloads") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    bad_bodies = [
      { description: "missing title" },
      { title: "missing description" },
      { title: "   ", description: "blank title" },
      { title: "t", description: "   " },
      { title: "T" * 501, description: "too long title" },
      { title: "t", description: "D" * 8001 },
      { title: 123, description: "wrong type" },
      { title: "t", description: "d", source: "x" },
      { title: "t", description: "d", status: "done", priority: 1, provider: "codex" },
      { title: "t", description: "d", plugin: "admin", worker: "w", commands: [] },
      ["not", "an", "object"]
    ]
    bad_bodies.each_with_index do |body, index|
      TaskRequestTestSupport.api_post(http, body, key: "invalid-#{index}-#{SecureRandom.hex(4)}")
      expect(http.last_response.status).to eq(422)
      parsed = JSON.parse(http.last_response.body)
      expect(parsed["error"]).to eq("invalid_payload")
      expect(http.last_response.body.include?("secret-marker-never-present")).to eq(false)
    end
    expect(TaskRequest.count).to eq(0)
    expect(ExternalEvent.count).to eq(0)
  end
end

test("API rejects U+0000 strings without partial rows") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    TaskRequestTestSupport.with_captured_debug_logs do |logs|
      [
        { title: "bad\u0000title", description: "d" },
        { title: "t", description: "bad\u0000desc" },
        { title: "\u0000title", description: "d" },
        { title: "t", description: "description\u0000" }
      ].each do |payload|
        TaskRequestTestSupport.api_post(http, payload, key: "nul-#{SecureRandom.hex(4)}")
        expect(http.last_response.status).to eq(422)
      end
      expect(TaskRequest.count).to eq(0)
      expect(ExternalEvent.count).to eq(0)
      expect(logs.string.include?("bad")).to eq(false)
    end
    TaskRequestTestSupport.api_post(http, { title: "日本語\n改行あり", description: "絵文字😀\n複数行\nOK" },
      key: "unicode-ok-#{SecureRandom.hex(4)}")
    expect(http.last_response.status).to eq(202)
    expect(TaskRequest.count).to eq(1)
  end
end

test("API requires a bounded Idempotency-Key") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    TaskRequestTestSupport.api_post(http, { title: "t", description: "d" }, key: nil)
    expect(http.last_response.status).to eq(422)
    expect(JSON.parse(http.last_response.body)["error"]).to eq("invalid_idempotency_key")
    TaskRequestTestSupport.api_post(http, { title: "t", description: "d" }, key: "has space")
    expect(http.last_response.status).to eq(422)
    TaskRequestTestSupport.api_post(http, { title: "t", description: "d" }, key: "k" * 129)
    expect(http.last_response.status).to eq(422)
    expect(TaskRequest.count).to eq(0)
  end
end

test("API POST creates a receipt without Task or TaskRun and returns 202") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    key = "api-key-#{SecureRandom.hex(8)}"
    TaskRequestTestSupport.api_post(http, { title: "Fix login", description: "Steps" }, key: key)
    expect(http.last_response.status).to eq(202)
    parsed = JSON.parse(http.last_response.body)
    expect(parsed["request_id"].match?(TaskRequestTestSupport::UUID_RE)).to eq(true)
    expect(parsed["request_id"] == key).to eq(false)
    expect(parsed["status"]).to eq("accepted")
    expect(parsed["task_id"]).to eq(nil)
    location = http.last_response.headers["Location"]
    expect(location).to eq("/api/admin/task_requests/#{parsed["request_id"]}")
    expect(Task.count).to eq(0)
    expect(TaskRun.count).to eq(0)
    receipt = TaskRequest.find_by!(request_id: parsed["request_id"])
    expect(receipt.idempotency_namespace).to eq("api")
    event = receipt.external_event
    expect(event.plugin).to eq("admin")
    expect(event.actor_id).to eq("admin-api")
    expect(event.payload["request_id"]).to eq(receipt.request_id)
  end
end

test("API same key same payload returns the same receipt") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    key = "api-retry-#{SecureRandom.hex(8)}"
    payload = { title: "retry", description: "same" }
    TaskRequestTestSupport.api_post(http, payload, key: key)
    first = JSON.parse(http.last_response.body)["request_id"]
    TaskRequestTestSupport.api_post(http, payload, key: key)
    expect(http.last_response.status).to eq(202)
    second = JSON.parse(http.last_response.body)["request_id"]
    expect(second).to eq(first)
    expect(TaskRequest.count).to eq(1)
    expect(ExternalEvent.count).to eq(1)
  end
end

test("API same key different payload conflicts") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    key = "api-conflict-#{SecureRandom.hex(8)}"
    TaskRequestTestSupport.api_post(http, { title: "first", description: "one" }, key: key)
    expect(http.last_response.status).to eq(202)
    TaskRequestTestSupport.api_post(http, { title: "second", description: "two" }, key: key)
    expect(http.last_response.status).to eq(409)
    expect(JSON.parse(http.last_response.body)["error"]).to eq("idempotency_conflict")
    expect(TaskRequest.count).to eq(1)
    expect(ExternalEvent.count).to eq(1)
  end
end

test("API distinct keys create independent receipts") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    TaskRequestTestSupport.api_post(http, { title: "one", description: "first" },
      key: "api-a-#{SecureRandom.hex(8)}")
    TaskRequestTestSupport.api_post(http, { title: "two", description: "second" },
      key: "api-b-#{SecureRandom.hex(8)}")
    expect(TaskRequest.count).to eq(2)
    receipts = TaskRequest.order(:id).to_a
    expect(receipts.map(&:request_id).uniq.size).to eq(2)
    expect(receipts.map { |receipt| receipt.external_event.resource_id }.uniq.size).to eq(2)
  end
end

test("API GET returns receipts and never exposes other event rows") do |http:|
  other = ExternalEvent.create!(plugin: "github", event_id: "evt-api-1", fingerprint: "fp-api-1",
    event_type: "message", resource_id: "issue-1", actor_id: "alice", actor_type: "human",
    occurred_at: Time.current, payload: { "body" => "hello" })
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    key = "api-get-#{SecureRandom.hex(8)}"
    TaskRequestTestSupport.api_post(http, { title: "read me", description: "poll" }, key: key)
    request_id = JSON.parse(http.last_response.body)["request_id"]
    TaskRequestTestSupport.api_get(http, request_id)
    expect(http.last_response.status).to eq(200)
    parsed = JSON.parse(http.last_response.body)
    expect(parsed["request_id"]).to eq(request_id)
    expect(parsed["status"]).to eq("accepted")
    TaskRequestTestSupport.api_get(http, SecureRandom.uuid)
    expect(http.last_response.status).to eq(404)
    TaskRequestTestSupport.api_get(http, other.id)
    expect(http.last_response.status).to eq(404)
    TaskRequestTestSupport.api_get(http, other.event_id)
    expect(http.last_response.status).to eq(404)
  end
end

test("API polling is read-only") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    key = "api-poll-#{SecureRandom.hex(8)}"
    TaskRequestTestSupport.api_post(http, { title: "poll", description: "read-only" }, key: key)
    request_id = JSON.parse(http.last_response.body)["request_id"]
    jobs = SolidQueue::Job.where(class_name: "CoordinationTriageJob").count
    2.times do
      TaskRequestTestSupport.api_get(http, request_id)
      expect(http.last_response.status).to eq(200)
    end
    expect(Task.count).to eq(0)
    expect(TaskRequest.count).to eq(1)
    expect(SolidQueue::Job.where(class_name: "CoordinationTriageJob").count).to eq(jobs)
  end
end

test("API ancestry stays separate from UI session protection") do |http:|
  expect(Api::Admin::BaseController.ancestors.include?(ActionController::API)).to eq(true)
  expect(Api::Admin::BaseController.ancestors.include?(ActionController::Base)).to eq(false)
  expect(Admin::BaseController.ancestors.include?(ActionController::Base)).to eq(true)
end

test("API preserves the full title500 and description8000 contract") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    TaskRequestTestSupport.api_post(http, { title: "T" * 500, description: "D" * 8000 },
      key: "api-full-#{SecureRandom.hex(8)}")
    expect(http.last_response.status).to eq(202)
    request_id = JSON.parse(http.last_response.body)["request_id"]
    receipt = TaskRequest.find_by!(request_id: request_id)
    expect(receipt.title.size).to eq(500)
    expect(receipt.description.size).to eq(8000)
    expect(receipt.external_event.payload["title"].size).to eq(500)
    expect(receipt.external_event.payload["description"].size).to eq(8000)
    expect(Task.count).to eq(0)
  end
end

test("API accepts valid maximum Unicode payload with escaped surrogates") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    title = "😀" * 500
    description = "🦄" * 8000
    escaped = JSON.generate({ title: title, description: description }, ascii_only: true)
    expect(escaped.bytesize < ApiTaskRequestBodyGuard::LIMIT_BYTES).to eq(true)
    TaskRequestTestSupport.api_post(http, escaped, key: "api-unicode-max-#{SecureRandom.hex(4)}")
    expect(http.last_response.status).to eq(202)
    request_id = JSON.parse(http.last_response.body)["request_id"]
    receipt = TaskRequest.find_by!(request_id: request_id)
    expect(receipt.title).to eq(title)
    expect(receipt.description).to eq(description)
  end
end

test("API rejects oversized input without rows or log contents") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    sentinel = "OVERSIZE-SENTINEL-#{SecureRandom.hex(8)}"
    big_title = "#{sentinel}-#{"A" * (ApiTaskRequestBodyGuard::LIMIT_BYTES + 1024)}"
    TaskRequestTestSupport.with_captured_debug_logs do |logs|
      TaskRequestTestSupport.api_post(http, { title: big_title, description: "d" },
        key: "api-oversize-#{SecureRandom.hex(4)}")
      expect(http.last_response.status).to eq(422)
      expect(JSON.parse(http.last_response.body)["error"]).to eq("invalid_payload")
      expect(TaskRequest.count).to eq(0)
      expect(ExternalEvent.count).to eq(0)
      expect(logs.string.include?(sentinel)).to eq(false)
    end
  end
end

test("API malformed JSON never reaches DEBUG logs") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    sentinel = "MALFORMED-SENTINEL-#{SecureRandom.hex(8)}"
    TaskRequestTestSupport.with_captured_debug_logs do |logs|
      TaskRequestTestSupport.api_post(http,
        %({"title":"#{sentinel}","description": }{"broken":),
        key: "api-malformed-#{SecureRandom.hex(4)}")
      expect(http.last_response.status).to eq(400)
      expect(JSON.parse(http.last_response.body)["error"]).to eq("malformed_json")
      expect(TaskRequest.count).to eq(0)
      expect(logs.string.include?(sentinel)).to eq(false)
    end
  end
end

test("API rejects invalid UTF-8 before schema validation without logging input") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    sentinel = "ENCODING-SENTINEL-#{SecureRandom.hex(8)}"
    raw = %({"title":").b + "\xff".b + %(","description":"#{sentinel}"}).b
    TaskRequestTestSupport.with_captured_debug_logs do |logs|
      TaskRequestTestSupport.api_post(http, raw, key: "invalid-utf8")
      expect(http.last_response.status).to eq(400)
      expect(JSON.parse(http.last_response.body)["error"]).to eq("malformed_json")
      expect(TaskRequest.count).to eq(0)
      expect(ExternalEvent.count).to eq(0)
      expect(logs.string.include?(sentinel)).to eq(false)
    end
  end
end

test("API bound checks actual body bytes despite an understated Content-Length") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    # The values meet the character schema; only JSON formatting exceeds
    # the body byte bound. Header-only checks would accept this request.
    raw = JSON.generate(title: "small", description: "small") + " " * ApiTaskRequestBodyGuard::LIMIT_BYTES
    env = Rack::MockRequest.env_for("http://#{AdminTestSupport::HOST}/api/admin/task_requests",
      method: "POST", input: raw, "CONTENT_TYPE" => "application/json",
      "HTTP_AUTHORIZATION" => "Bearer #{TaskRequestTestSupport::API_TOKEN}",
      "HTTP_IDEMPOTENCY_KEY" => "understated-length")
    env["CONTENT_LENGTH"] = "1"
    status, _, body = Rails.application.call(env)
    expect(status).to eq(422)
    expect(TaskRequest.count).to eq(0)
    expect(ExternalEvent.count).to eq(0)
  ensure
    body&.close if body.respond_to?(:close)
  end
end

test("API receipt reads ignore bodies without logging their contents") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    TaskRequestTestSupport.api_post(http, { title: "receipt", description: "read only" }, key: "read-body")
    id = JSON.parse(http.last_response.body).fetch("request_id")
    sentinel = "READBODY-SENTINEL-#{SecureRandom.hex(8)}"
    TaskRequestTestSupport.with_captured_debug_logs do |logs|
      env = Rack::MockRequest.env_for("http://#{AdminTestSupport::HOST}/api/admin/task_requests/#{id}",
        method: "GET", input: %({"title":"#{sentinel}","broken":),
        "CONTENT_TYPE" => "application/json",
        "HTTP_AUTHORIZATION" => "Bearer #{TaskRequestTestSupport::API_TOKEN}")
      status, _, body = Rails.application.call(env)
      expect(status).to eq(200)
      expect(logs.string.include?(sentinel)).to eq(false)
      expect(TaskRequest.count).to eq(1)
      expect(Task.count).to eq(0)
    ensure
      body&.close if body.respond_to?(:close)
    end
  end
end

test("API unknown-field values never reach DEBUG logs") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    sentinel = "UNKNOWNFIELD-SENTINEL-#{SecureRandom.hex(8)}"
    TaskRequestTestSupport.with_captured_debug_logs do |logs|
      TaskRequestTestSupport.api_post(http,
        { title: "t", description: "d", injected: sentinel, nested: { deep: sentinel } },
        key: "api-unknownlog-#{SecureRandom.hex(4)}")
      expect(http.last_response.status).to eq(422)
      expect(TaskRequest.count).to eq(0)
      expect(logs.string.include?(sentinel)).to eq(false)
    end
  end
end

test("API malformed body with bad auth still returns 401 without logging body") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    sentinel = "AUTHORDER-SENTINEL-#{SecureRandom.hex(8)}"
    TaskRequestTestSupport.with_captured_debug_logs do |logs|
      TaskRequestTestSupport.api_post(http, %({"title":"#{sentinel}","oops":),
        key: "api-authorder-#{SecureRandom.hex(4)}", token: "wrong-token")
      expect(http.last_response.status).to eq(401)
      expect(JSON.parse(http.last_response.body)["error"]).to eq("unauthorized")
      expect(TaskRequest.count).to eq(0)
      expect(logs.string.include?(sentinel)).to eq(false)
    end
    TaskRequestTestSupport.api_post(http, %({"title":"#{sentinel}","oops":),
      key: "api-authorder2-#{SecureRandom.hex(4)}")
    expect(http.last_response.status).to eq(400)
  end
end

test("API route variants stay guarded") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    sentinel = "VARIANT-SENTINEL-#{SecureRandom.hex(8)}"
    %w[
      /api/admin/task_requests.json /api/admin/task_requests/
      /api//admin/task_requests /api/admin//task_requests
      /api//admin///task_requests.json/
    ].each do |path|
      TaskRequestTestSupport.with_captured_debug_logs do |logs|
        TaskRequestTestSupport.api_post(http, %({"title":"#{sentinel}","oops":),
          key: "api-variant-#{SecureRandom.hex(4)}", path: path)
        expect(http.last_response.status).to eq(400)
        expect(logs.string.include?(sentinel)).to eq(false)
      end
    end
    TaskRequestTestSupport.api_post(http, { title: "variant-ok", description: "json suffix" },
      key: "api-variant-ok-#{SecureRandom.hex(4)}", path: "/api/admin/task_requests.json")
    expect(http.last_response.status).to eq(202)
    expect(TaskRequest.count).to eq(1)
  end
end

test("normal triage ingests an accepted API event") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    key = "api-triage-#{SecureRandom.hex(8)}"
    TaskRequestTestSupport.api_post(http, { title: "from api", description: "ingest me" }, key: key)
    request_id = JSON.parse(http.last_response.body)["request_id"]
    fake = WorkflowFakes::FakeAiRunner.new
    result = Coordination::TriageService.new(ai_runner: fake, event_sink: WorkflowFakes::FakeEventSink.new).call
    expect(result.ingested).to eq(1)
    receipt = TaskRequest.find_by!(request_id: request_id)
    expect(receipt.status).to eq("processed")
    expect(receipt.task_id.nil?).to eq(false)
    expect(Task.count).to eq(1)
    TaskRequestTestSupport.api_get(http, request_id)
    parsed = JSON.parse(http.last_response.body)
    expect(parsed["status"]).to eq("processed")
    expect(parsed["task_id"]).to eq(receipt.task_id)
  end
end
