# frozen_string_literal: true

require_relative "request_workflow_support"

# Real PostgreSQL, controllers, Coordination, Registry/adapters, AI Runner,
# schemas and EventLog. Only HTTP and the AI process boundary are scripted.
test("admin API request reads GitHub and completes only after one Teams delivery") do |http:|
  RequestAcceptance.with_context do |ctx|
    flow = RequestAcceptance::Workflow
    expect(Aiconshell::Observability.config.outbox.is_a?(EventLogging::OutboxAdapter)).to eq(true)
    payload = {
      title: "Urgent open issues",
      description: "Read o/r issues. Post urgent items to the configured Teams channel."
    }
    receipt_body = flow.api_post(http, payload, key: "urgent-review")
    expect(http.last_response.status).to eq(202)
    expect(receipt_body["status"]).to eq("accepted")
    expect(receipt_body["task_id"]).to eq(nil)
    receipt = TaskRequest.find_by!(request_id: receipt_body.fetch("request_id"))
    event = receipt.external_event
    expect(event.plugin).to eq("admin")
    expect(event.event_type).to eq("admin.task_request")
    expect(event.actor_type).to eq("human")
    expect(event.processed?).to eq(false)
    expect(event.task_id).to eq(nil)
    expect(Task.count).to eq(0)

    duplicate = flow.api_post(http, payload, key: "urgent-review")
    expect(http.last_response.status).to eq(202)
    expect(duplicate["request_id"]).to eq(receipt.request_id)
    expect(TaskRequest.count).to eq(1)
    expect(ExternalEvent.count).to eq(1)

    flow.configure_policy
    ctx.expect_github_token
    ctx.expect_github_issue_page(issues: [
      ctx.github_issue(number: 42, title: "Login outage", body: "Users cannot sign in", labels: ["priority:high"]),
      ctx.github_issue(number: 43, title: "Docs typo", body: "Minor text correction", labels: ["priority:low"])
    ])
    ctx.process_runner.enqueue(->(call) { flow.read_answer(call) })
    message = "Urgent: #42 Login outage — https://github.com/o/r/issues/42"
    summary = "Reviewed open issues and queued one urgent-issue notification."
    ctx.process_runner.enqueue(->(call) do
      flow.result_answer(call, summary: summary, actions: [flow.teams_action(message)])
    end)

    triage = flow.triage(ctx)
    outcome = triage.call
    expect(outcome.ingested).to eq(1)
    expect(outcome.triaged).to eq(1)
    task = receipt.external_event.reload.task
    expect(task.status).to eq("waiting_delivery")
    expect(task.priority).to eq(10)
    expect(task.coordination_result).to eq({ "summary" => summary, "action_count" => 1 })
    expect(task.task_runs.count).to eq(0)
    expect(event.reload.processed?).to eq(true)
    action = task.outbound_actions.sole
    expect(action.status).to eq("pending")
    expect(action.plugin).to eq("teams")
    expect(action.operation).to eq("send_message")
    expect(action.input).to eq({ "scope" => RequestAcceptance::TEAMS_WRITE_TARGET, "body" => message })
    expect(action.delivery_batch_key).to eq(task.delivery_batch_key)
    expect(task.delivery_batch_key.present?).to eq(true)
    expect(ctx.teams_posts).to eq([])

    calls = ctx.process_runner.calls
    expect(calls.size).to eq(2)
    observation = flow.prompt_data(calls.last, "OBSERVATIONS").sole
    expect(observation.slice("task_id", "round", "plugin", "operation", "input")).to eq({
      "task_id" => task.id, "round" => 1, "plugin" => "github", "operation" => "list_issues",
      "input" => { "scope" => "o/r" }
    })
    output = observation.fetch("output")
    expect(output["complete"]).to eq(true)
    expect(output["next_cursor"]).to eq(nil)
    expect(output["issues"].map { |issue| issue["number"] }).to eq([42, 43])
    expect(output["issues"].first.slice("title", "body", "labels")).to eq({
      "title" => "Login outage", "body" => "Users cannot sign in", "labels" => ["priority:high"]
    })
    targets = flow.prompt_data(calls.first, "CAPABILITIES").fetch("allowed_targets")
    expect(targets.include?({
      "plugin" => "teams", "permission_scope" => RequestAcceptance::TEAMS_CHANNEL_SCOPE,
      "input_scope" => RequestAcceptance::TEAMS_WRITE_TARGET
    })).to eq(true)
    calls.each do |call|
      expect(call[:argv].first.end_with?("/claude")).to eq(true)
      expect(call[:argv][call[:argv].index("--model") + 1]).to eq("fixture-model")
      expect(call[:argv][call[:argv].index("--effort") + 1]).to eq("max")
      expect(call[:argv].include?(call[:stdin_data])).to eq(false)
      %w[DATABASE_URL TEST_DATABASE_URL GITHUB_PRIVATE_KEY TEAMS_CLIENT_SECRET TEAMS_BOT_APP_PASSWORD
         ADMIN_USERNAME ADMIN_PASSWORD ADMIN_API_TOKEN].each do |key|
        expect(call[:env].key?(key)).to eq(false)
      end
      expect(File.realpath(call[:cwd]).start_with?(File.realpath(ctx.execution_root) + "/")).to eq(true)
    end
    get = ctx.transport.requests_to(RequestAcceptance::GITHUB_ISSUES_PATTERN, method: "GET").sole
    expect(URI.decode_www_form(URI(get[:url]).query).to_h.slice("state", "sort", "direction", "page")).to eq({
      "state" => "open", "sort" => "created", "direction" => "desc", "page" => "1"
    })
    expect(get[:headers]["Authorization"]).to eq("Bearer ghs_fixture_installation_token")

    status = flow.api_get(http, receipt.request_id)
    expect(http.last_response.status).to eq(200)
    expect(status.slice("status", "task_id")).to eq({ "status" => "processed", "task_id" => task.id })
    expect(triage.call.triaged).to eq(0)
    expect(task.outbound_actions.count).to eq(1)

    ctx.expect_teams_token
    ctx.expect_teams_post(external_id: "fixture-activity-42")
    delivery = Interaction::OutboundService.new(registry: ctx.registry, ai_runner: ctx.runner, clock: ctx.clock)
    expect(delivery.call(action.id).ok).to eq(true)
    expect(action.reload.status).to eq("sent")
    expect(action.external_id).to eq("fixture-activity-42")
    expect(task.reload.status).to eq("waiting_delivery")
    expect(ctx.teams_posts.size).to eq(1)
    wire = ctx.teams_posts.sole
    expect(JSON.parse(wire[:body])).to eq({ "type" => "message", "text" => message })
    expect(wire[:headers]["Authorization"]).to eq("Bearer fixture-bot-token")

    reconciler = Coordination::DeliveryReconciler.new(clock: ctx.clock)
    expect(reconciler.reconcile(task_id: task.id).code).to eq(:settled_done)
    expect(task.reload.status).to eq("done")
    expect(delivery.call(action.id).code).to eq(:duplicate_delivery)
    expect(reconciler.reconcile(task_id: task.id).code).to eq(:not_waiting_delivery)
    expect(triage.call.triaged).to eq(0)
    expect(flow.api_post(http, payload, key: "urgent-review")["request_id"]).to eq(receipt.request_id)
    expect([TaskRequest.count, ExternalEvent.count, Task.count, OutboundAction.count, TaskRun.count]).to eq([1, 1, 1, 1, 0])
    expect(ctx.teams_posts.size).to eq(1)
    expect(ctx.process_runner.calls.size).to eq(2)

    %w[triage.ingested query.completed result.applied outbound.sent delivery.settled].each do |kind|
      expect(EventDelivery.where(kind: kind).exists?).to eq(true)
    end
    EventDelivery.find_each do |row|
      expect(row.envelope["event_id"]).to eq(row.event_id)
      expect(row.envelope["kind"]).to eq(row.kind)
    end
    serialized = flow.event_text
    ["ghs_fixture_installation_token", "fixture-bot-token", "TASKS:", "OBSERVATIONS:",
     "structured_output", payload[:description], message].each do |private_text|
      expect(serialized.include?(private_text)).to eq(false)
    end
    ctx.assert_consumed!
  end
end

test("admin UI submits a CSRF-protected request through the same real intake") do |http:|
  RequestAcceptance.with_context do |ctx|
    flow = RequestAcceptance::Workflow
    previous_csrf = ActionController::Base.allow_forgery_protection
    begin
      ActionController::Base.allow_forgery_protection = true
      http.get("/admin/task_requests/new", {}, flow.admin_headers)
      expect(http.last_response.status).to eq(200)
      form = Nokogiri::HTML(http.last_response.body)
      csrf = form.at_css('input[name="authenticity_token"]')["value"]
      key = form.at_css('input[name="idempotency_key"]')["value"]
      expect(csrf.to_s.empty?).to eq(false)
      description = "Review o/r open issues.\nReport only urgent work <script>fixture()</script>."
      http.post("/admin/task_requests", {
        "authenticity_token" => csrf, "idempotency_key" => key,
        "task_request" => { "title" => "UI issue review", "description" => description }
      }, flow.admin_headers)
      expect(http.last_response.status).to eq(302)
      receipt = TaskRequest.sole
      event = receipt.external_event
      expect(receipt.idempotency_namespace).to eq("ui")
      expect(event.actor_id).to eq("admin")
      expect(event.payload["description"]).to eq(description)
      expect(Task.count).to eq(0)
      http.get(http.last_response.headers.fetch("Location"), {}, flow.admin_headers)
      expect(http.last_response.status).to eq(200)
      expect(http.last_response.body.include?("<script>fixture()</script>")).to eq(false)

      flow.configure_policy
      ctx.process_runner.enqueue(->(call) do
        flow.result_answer(call, summary: "Reviewed request; no notification needed.", priority: 1)
      end)
      expect(flow.triage(ctx).call.triaged).to eq(1)
      task = event.reload.task
      expect(task.status).to eq("done")
      expect(task.description).to eq(description)
      prompt = flow.prompt_data(ctx.process_runner.calls.sole, "TASKS").sole
      expect(prompt["description"]).to eq(description)
      expect(prompt["admin_request"]).to eq(true)
      expect(task.outbound_actions.count).to eq(0)
      expect(ctx.teams_posts).to eq([])
      ctx.assert_consumed!
    ensure
      ActionController::Base.allow_forgery_protection = previous_csrf
    end
  end
end

test("a complete GitHub page with no urgent issues finishes with zero Teams writes") do |http:|
  RequestAcceptance.with_context do |ctx|
    flow = RequestAcceptance::Workflow
    receipt = flow.submit(http)
    flow.configure_policy
    ctx.expect_github_token
    ctx.expect_github_issue_page(issues: [
      ctx.github_issue(number: 7, title: "Improve examples", body: "Optional cleanup", labels: ["priority:low"])
    ])
    ctx.process_runner.enqueue(->(call) { flow.read_answer(call) })
    ctx.process_runner.enqueue(->(call) do
      flow.result_answer(call, summary: "No urgent issues in the complete open-issue list.", priority: 1)
    end)

    expect(flow.triage(ctx).call.triaged).to eq(1)
    task = receipt.external_event.reload.task
    expect(task.status).to eq("done")
    expect(task.coordination_result["action_count"]).to eq(0)
    observed = flow.prompt_data(ctx.process_runner.calls.last, "OBSERVATIONS").sole.fetch("output")
    expect(observed["complete"]).to eq(true)
    expect(observed["issues"].sole["labels"]).to eq(["priority:low"])
    expect(OutboundAction.count).to eq(0)
    expect(TaskRun.count).to eq(0)
    expect(ctx.teams_posts).to eq([])
    expect(ctx.transport.requests_to(RequestAcceptance::TEAMS_TOKEN_URL)).to eq([])
    ctx.assert_consumed!
  end
end

test("partial and truncated GitHub results reach the next AI decision unchanged") do |http:|
  RequestAcceptance.with_context do |ctx|
    flow = RequestAcceptance::Workflow
    receipt = flow.submit(http)
    flow.configure_policy
    next_page = "https://api.github.com/repos/o/r/issues?state=open&sort=created&direction=desc&per_page=30&page=2"
    ctx.expect_github_token
    ctx.expect_github_issue_page(issues: [
      ctx.github_issue(number: 8, title: "Long investigation", body: "x" * 2100, labels: ["needs-triage"])
    ], next_page: next_page)
    ctx.process_runner.enqueue(->(call) { flow.read_answer(call) })
    summary = "Reviewed only the first page; the issue body was truncated. No complete-scan conclusion."
    ctx.process_runner.enqueue(->(call) { flow.result_answer(call, summary: summary) })

    expect(flow.triage(ctx).call.triaged).to eq(1)
    observed = flow.prompt_data(ctx.process_runner.calls.last, "OBSERVATIONS").sole.fetch("output")
    expect(observed["complete"]).to eq(false)
    expect(observed["next_cursor"]).to eq({ "version" => 1, "scope" => "o/r", "page" => 2 })
    expect(observed["truncated"]).to eq(true)
    expect(observed["limit_reached"]).to eq(false)
    expect(observed["issues"].sole["body_truncated"]).to eq(true)
    expect(observed["issues"].sole["body"].bytesize <= 2000).to eq(true)
    task = receipt.external_event.reload.task
    expect(task.status).to eq("done")
    expect(task.coordination_result["summary"]).to eq(summary)
    expect(OutboundAction.count).to eq(0)
    expect(ctx.teams_posts).to eq([])
    expect(ctx.transport.requests_to(RequestAcceptance::GITHUB_ISSUES_PATTERN, method: "GET").size).to eq(1)
    ctx.assert_consumed!
  end
end
