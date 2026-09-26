# frozen_string_literal: true

require "db_helper"
require "securerandom"
require_relative "support/admin_test_support"
require_relative "support/task_request_test_support"
require_relative "../../fixtures/workflow_fakes"

test("board links to new task request") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks"
    expect(http.last_response.status).to eq(200)
    expect(http.last_response.body.include?("/admin/task_requests/new")).to eq(true)
    expect(http.last_response.body.include?("タスク依頼を作成する")).to eq(true)
  end
end

test("unauthenticated UI task request routes return 401") do |http:|
  AdminTestSupport.as_anonymous(http) do
    http.get "/admin/task_requests/new"
    expect(http.last_response.status).to eq(401)
    http.post "/admin/task_requests", { task_request: { title: "x", description: "y" } }
    expect(http.last_response.status).to eq(401)
    http.get "/admin/task_requests/#{SecureRandom.uuid}"
    expect(http.last_response.status).to eq(401)
  end
end

test("new form carries a server UUID idempotency key") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    expect(http.last_response.status).to eq(200)
    key = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    expect(key.nil?).to eq(false)
    expect(key.match?(TaskRequestTestSupport::UUID_RE)).to eq(true)
    expect(http.last_response.body.include?("task_request[title]")).to eq(true)
    expect(http.last_response.body.include?("task_request[description]")).to eq(true)
    expect(http.last_response.body.include?("タスク依頼の作成")).to eq(true)
    expect(http.last_response.body.include?("依頼を送る")).to eq(true)
    expect(http.last_response.body.include?("New task request")).to eq(false)
  end
end

test("UI POST creates receipt and event without Task or TaskRun") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    key = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    http.post "/admin/task_requests",
      { task_request: { title: "Fix login", description: "Steps to reproduce" }, idempotency_key: key }
    expect(http.last_response.status).to eq(302)
    location = http.last_response.headers["Location"]
    expect(location.include?("/admin/task_requests/")).to eq(true)
    expect(Task.count).to eq(0)
    expect(TaskRun.count).to eq(0)
    expect(TaskRequest.count).to eq(1)
    receipt = TaskRequest.last
    expect(receipt.idempotency_namespace).to eq("ui")
    expect(receipt.request_id.match?(TaskRequestTestSupport::UUID_RE)).to eq(true)
    expect(receipt.request_id == key).to eq(false)
    event = receipt.external_event
    expect(event.plugin).to eq("admin")
    expect(event.event_type).to eq("admin.task_request")
    expect(event.actor_type).to eq("human")
    expect(event.event_id.match?(TaskRequestTestSupport::UUID_RE)).to eq(true)
    expect(event.resource_id.match?(TaskRequestTestSupport::UUID_RE)).to eq(true)
    expect(event.event_id == key).to eq(false)
    expect(event.resource_id == key).to eq(false)
    expect(event.payload["title"]).to eq("Fix login")
    expect(event.payload["description"]).to eq("Steps to reproduce")
    expect(event.payload["request_id"]).to eq(receipt.request_id)
    expect(receipt.status).to eq("accepted")
    expect(receipt.task_id).to eq(nil)
    http.follow_redirect!
    expect(http.last_response.status).to eq(200)
    expect(http.last_response.body.include?("タスク整理待ち")).to eq(true)
    expect(http.last_response.body.include?("依頼を受け付けました")).to eq(true)
    expect(http.last_response.body.include?(receipt.request_id)).to eq(true)
    expect(http.last_response.body.include?("Durable receipt")).to eq(false)
    expect(http.last_response.body.include?("Coordination")).to eq(false)
  end
end

test("UI POST rejects unknown nested fields") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    key = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    http.post "/admin/task_requests",
      { task_request: { title: "t", description: "d", source: "x", status: "done",
                        priority: 9, provider: "codex", worker: "w", command: "run",
                        plugin: "admin", body: "nested-body", event_id: "e1" },
        idempotency_key: key }
    expect(http.last_response.status).to eq(422)
    expect(TaskRequest.count).to eq(0)
    expect(ExternalEvent.count).to eq(0)
    expect(http.last_response.body.include?("使用できない入力項目")).to eq(true)
    kept = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    expect(kept).to eq(key)
  end
end

test("UI POST rejects unknown top-level fields") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    key = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    %w[plugin source status priority provider worker commands body event_id event_type
       resource_id actor_id actor_type title description].each do |field|
      http.post "/admin/task_requests",
        { task_request: { title: "t", description: "d" }, idempotency_key: key, field => "injected" }
      expect(http.last_response.status).to eq(422)
    end
    expect(TaskRequest.count).to eq(0)
    expect(ExternalEvent.count).to eq(0)
    http.post "/admin/task_requests",
      { task_request: { title: "t", description: "d" }, idempotency_key: key, plugin: "admin" }
    expect(http.last_response.body.include?("使用できない入力項目")).to eq(true)
    kept = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    expect(kept).to eq(key)
  end
end

test("UI keeps title and description scalar types strict") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    key = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    http.post "/admin/task_requests",
      { task_request: { title: ["array", "title"], description: "d" }, idempotency_key: key }
    expect(http.last_response.status).to eq(422)
    expect(TaskRequest.count).to eq(0)
    http.post "/admin/task_requests",
      { task_request: { title: "t", description: { nested: "hash" } }, idempotency_key: key }
    expect(http.last_response.status).to eq(422)
    expect(TaskRequest.count).to eq(0)
    expect(ExternalEvent.count).to eq(0)
  end
end

test("UI validation errors preserve retry key and values") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    key = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    http.post "/admin/task_requests",
      { task_request: { title: "   ", description: "keep me" }, idempotency_key: key }
    expect(http.last_response.status).to eq(422)
    expect(TaskRequest.count).to eq(0)
    kept = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    expect(kept).to eq(key)
    expect(http.last_response.body.include?("keep me")).to eq(true)
    expect(http.last_response.body.include?("タイトル")).to eq(true)
  end
end

test("UI redisplayed validation inputs escape quotes and tags") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    key = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    evil_title = %("quoted" <b>bold</b>)
    evil_desc = %(<script>alert('x')</script> "desc")
    http.post "/admin/task_requests",
      { task_request: { title: "   ", description: evil_desc }, idempotency_key: key }
    expect(http.last_response.status).to eq(422)
    body = http.last_response.body
    expect(body.include?("<script>alert('x')</script>")).to eq(false)
    expect(body.include?("&lt;script&gt;")).to eq(true)
    kept = TaskRequestTestSupport.extract_key(body, "idempotency_key")
    expect(kept).to eq(key)
    http.post "/admin/task_requests",
      { task_request: { title: evil_title, description: "   " }, idempotency_key: key }
    expect(http.last_response.status).to eq(422)
    body2 = http.last_response.body
    expect(body2.include?("<b>bold</b>")).to eq(false)
    expect(body2.include?("&lt;b&gt;")).to eq(true)
    expect(body2.include?("&quot;quoted&quot;")).to eq(true)
  end
end

test("UI same key same payload returns the existing receipt") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    key = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    payload = { task_request: { title: "retry", description: "same" }, idempotency_key: key }
    http.post "/admin/task_requests", payload
    first = http.last_response.headers["Location"]
    http.post "/admin/task_requests", payload
    expect(http.last_response.status).to eq(302)
    expect(http.last_response.headers["Location"]).to eq(first)
    expect(TaskRequest.count).to eq(1)
    expect(ExternalEvent.count).to eq(1)
  end
end

test("UI same key different payload conflicts without a new receipt") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    key = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    http.post "/admin/task_requests",
      { task_request: { title: "first", description: "one" }, idempotency_key: key }
    expect(http.last_response.status).to eq(302)
    http.post "/admin/task_requests",
      { task_request: { title: "second", description: "two" }, idempotency_key: key }
    expect(http.last_response.status).to eq(409)
    expect(TaskRequest.count).to eq(1)
    expect(ExternalEvent.count).to eq(1)
    expect(http.last_response.body.include?("別の内容で送信済み")).to eq(true)
  end
end

test("UI distinct keys create independent receipts with own identities") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    key1 = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    http.get "/admin/task_requests/new"
    key2 = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    expect(key1 == key2).to eq(false)
    http.post "/admin/task_requests",
      { task_request: { title: "one", description: "first" }, idempotency_key: key1 }
    http.post "/admin/task_requests",
      { task_request: { title: "two", description: "second" }, idempotency_key: key2 }
    expect(TaskRequest.count).to eq(2)
    receipts = TaskRequest.order(:id).to_a
    expect(receipts.map(&:request_id).uniq.size).to eq(2)
    resources = receipts.map { |receipt| receipt.external_event.resource_id }
    expect(resources.uniq.size).to eq(2)
    events = receipts.map { |receipt| receipt.external_event.event_id }
    expect(events.uniq.size).to eq(2)
  end
end

test("UI receipt escapes quotes and tags in user content") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    key = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    http.post "/admin/task_requests",
      { task_request: { title: %(<script>alert("t")</script> "quoted"),
                        description: %(<img src=x onerror=alert(1)> 'single') },
        idempotency_key: key }
    expect(http.last_response.status).to eq(302)
    http.follow_redirect!
    body = http.last_response.body
    expect(body.include?(%(<script>alert("t")</script>))).to eq(false)
    expect(body.include?("<img src=x onerror=alert(1)>")).to eq(false)
    expect(body.include?("&lt;script&gt;")).to eq(true)
    expect(body.include?("&lt;img")).to eq(true)
  end
end

test("UI unknown receipt never exposes ExternalEvent rows") do |http:|
  event = ExternalEvent.create!(plugin: "github", event_id: "evt-1", fingerprint: "fp-1",
    event_type: "message", resource_id: "issue-1", actor_id: "alice", actor_type: "human",
    occurred_at: Time.current, payload: { "body" => "hello" })
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/#{event.id}"
    expect(http.last_response.status).to eq(302)
    http.get "/admin/task_requests/#{event.event_id}"
    expect(http.last_response.status).to eq(302)
    http.get "/admin/task_requests/#{SecureRandom.uuid}"
    expect(http.last_response.status).to eq(302)
  end
end

test("UI receipt polling is read-only") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    key = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    http.post "/admin/task_requests",
      { task_request: { title: "poll", description: "read-only" }, idempotency_key: key }
    receipt = TaskRequest.last
    jobs = SolidQueue::Job.where(class_name: "CoordinationTriageJob").count
    2.times do
      http.get "/admin/task_requests/#{receipt.request_id}"
      expect(http.last_response.status).to eq(200)
    end
    expect(Task.count).to eq(0)
    expect(TaskRequest.count).to eq(1)
    expect(SolidQueue::Job.where(class_name: "CoordinationTriageJob").count).to eq(jobs)
  end
end

test("UI CSRF without token is rejected and with token succeeds") do |http:|
  AdminTestSupport.as_admin(http) do
    AdminTestSupport.with_forgery_protection do
      http.get "/admin/task_requests/new"
      body = http.last_response.body
      key = TaskRequestTestSupport.extract_key(body, "idempotency_key")
      token = body[/name="authenticity_token" value="([^"]+)"/, 1]
      expect(token.nil?).to eq(false)
      http.post "/admin/task_requests",
        { task_request: { title: "forged", description: "no token" }, idempotency_key: key }
      expect(http.last_response.status).to eq(422)
      expect(TaskRequest.count).to eq(0)
      http.post "/admin/task_requests",
        { task_request: { title: "genuine", description: "with token" },
          idempotency_key: key, authenticity_token: token }
      expect(http.last_response.status).to eq(302)
      expect(TaskRequest.count).to eq(1)
    end
  end
end

test("UI preserves the full title500 and description8000 contract") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    key = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    long_title = "T" * 500
    long_body = "D" * 8000
    http.post "/admin/task_requests",
      { task_request: { title: long_title, description: long_body }, idempotency_key: key }
    expect(http.last_response.status).to eq(302)
    receipt = TaskRequest.last
    expect(receipt.title.size).to eq(500)
    expect(receipt.description.size).to eq(8000)
    expect(receipt.external_event.payload["title"].size).to eq(500)
    expect(receipt.external_event.payload["description"].size).to eq(8000)
    expect(Task.count).to eq(0)
  end
end

test("normal triage ingests an accepted UI event and links the Task") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/task_requests/new"
    key = TaskRequestTestSupport.extract_key(http.last_response.body, "idempotency_key")
    http.post "/admin/task_requests",
      { task_request: { title: "short title", description: "short body for triage" },
        idempotency_key: key }
    expect(http.last_response.status).to eq(302)
    receipt = TaskRequest.last
    fake = WorkflowFakes::FakeAiRunner.new
    result = Coordination::TriageService.new(ai_runner: fake, event_sink: WorkflowFakes::FakeEventSink.new).call
    expect(result.ingested).to eq(1)
    expect(fake.calls.empty?).to eq(true)
    receipt = TaskRequest.find(receipt.id)
    event = receipt.external_event
    expect(event.processed?).to eq(true)
    expect(event.task.nil?).to eq(false)
    expect(Task.count).to eq(1)
    expect(TaskRun.count).to eq(0)
    expect(receipt.status).to eq("processed")
    expect(receipt.task_id).to eq(event.task_id)
    http.get "/admin/task_requests/#{receipt.request_id}"
    expect(http.last_response.status).to eq(200)
    expect(http.last_response.body.include?("タスク作成済み")).to eq(true)
    expect(http.last_response.body.include?("/admin/tasks/#{event.task_id}")).to eq(true)
  end
end

test("request content stays out of filtered logs") do |http:|
  filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  filtered = filter.filter({ title: "secret-title", description: "secret-body", body: "secret-b",
                             idempotency_key: "secret-key", request_id: "visible" })
  expect(filtered[:title]).to eq("[FILTERED]")
  expect(filtered[:description]).to eq("[FILTERED]")
  expect(filtered[:body]).to eq("[FILTERED]")
  expect(filtered[:idempotency_key]).to eq("[FILTERED]")
  expect(filtered[:request_id]).to eq("visible")
end
