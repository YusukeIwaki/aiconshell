# frozen_string_literal: true

require_relative "request_workflow_support"

# PostgreSQL acceptance failures exercise the actual AI parser, schema
# validators, HTTP classification and delivery lifecycle at their boundaries.
test("invalid provider output is rejected before any connector call") do |http:|
  RequestAcceptance.with_context do |ctx|
    flow = RequestAcceptance::Workflow
    receipt = flow.submit(http)
    flow.configure_policy
    canary = "RAW-PROVIDER-OUTPUT-SHOULD-NOT-ESCAPE"
    ctx.process_runner.enqueue(Aiconshell::Ai::Result.new(
      stdout: "invalid JSON #{canary}", stderr: "provider detail #{canary}",
      exit_status: 0, timed_out: false, stdout_truncated: false, stderr_truncated: false
    ))

    expect(flow.triage(ctx).call.triaged).to eq(0)
    task = receipt.external_event.reload.task
    expect(task.status).to eq("inbox")
    expect(task.last_error).to eq("Coordination failed (provider_invalid_output)")
    expect(task.next_action_at).to eq(ctx.clock.now + 3600)
    expect(task.coordination_result).to eq(nil)
    expect(OutboundAction.count).to eq(0)
    expect(TaskRun.count).to eq(0)
    expect(ctx.transport.requests).to eq([])
    expect(ctx.process_runner.calls.size).to eq(1)
    expect(EventDelivery.where(kind: "triage.ai_failed").exists?).to eq(true)
    expect(flow.event_text.include?(canary)).to eq(false)
    status = flow.api_get(http, receipt.request_id)
    expect(status["last_error"]).to eq(task.last_error)
    expect(http.last_response.body.include?(canary)).to eq(false)
    ctx.assert_consumed!
  end
end

test("real AI schema rejects mixed read and result decisions without connector calls") do |http:|
  RequestAcceptance.with_context do |ctx|
    flow = RequestAcceptance::Workflow
    receipt = flow.submit(http)
    flow.configure_policy
    ctx.process_runner.enqueue(->(call) do
      flow.read_answer(call).merge(flow.result_answer(call, summary: "Invalid mixed decision"))
    end)

    expect(flow.triage(ctx).call.triaged).to eq(0)
    task = receipt.external_event.reload.task
    expect(task.last_error).to eq("Coordination failed (provider_invalid_output)")
    expect(task.coordination_result).to eq(nil)
    expect(OutboundAction.count).to eq(0)
    expect(ctx.transport.requests).to eq([])
    ctx.assert_consumed!
  end
end

test("a forbidden Discord target rejects the whole result before any write") do |http:|
  RequestAcceptance.with_context do |ctx|
    flow = RequestAcceptance::Workflow
    receipt = flow.submit(http)
    flow.configure_policy
    ctx.process_runner.enqueue(->(call) do
      flow.result_answer(call, summary: "Must reject both actions", actions: [
        flow.discord_action("Allowed action must not escape"),
        flow.discord_action("Forbidden action", scope: "channel:999000111222333444")
      ])
    end)

    result = flow.triage(ctx).call
    expect(result.triaged).to eq(0)
    expect(result.rejected).to eq(1)
    task = receipt.external_event.reload.task
    expect(task.status).to eq("inbox")
    expect(task.priority).to eq(0)
    expect(task.coordination_result).to eq(nil)
    expect(task.delivery_batch_key).to eq(nil)
    expect(OutboundAction.count).to eq(0)
    expect(ctx.transport.requests).to eq([])
    ctx.assert_consumed!
  end
end

%w[duplicate unknown].each do |reference|
  test("a #{reference} task reference rejects the complete final result round") do |http:|
    RequestAcceptance.with_context do |ctx|
      flow = RequestAcceptance::Workflow
      receipt = flow.submit(http)
      flow.configure_policy
      ctx.process_runner.enqueue(->(call) do
        first = flow.result_answer(call, summary: "First valid result",
                                  actions: [flow.discord_action("Must not be sent")]).fetch("rulings").sole
        second_id = reference == "duplicate" ? first.fetch("task_id") : first.fetch("task_id") + 1_000_000
        {
          "rulings" => [
            first,
            { "task_id" => second_id, "result" => { "summary" => "Invalid task reference", "actions" => [] } }
          ]
        }
      end)

      result = flow.triage(ctx).call
      expect(result.triaged).to eq(0)
      expect(result.rejected).to eq(2)
      task = receipt.external_event.reload.task
      expect(task.status).to eq("inbox")
      expect(task.priority).to eq(0)
      expect(task.coordination_result).to eq(nil)
      expect(task.delivery_batch_key).to eq(nil)
      expect(OutboundAction.count).to eq(0)
      expect(ctx.transport.requests).to eq([])
      ctx.assert_consumed!
    end
  end
end

test("GitHub rate limiting aborts the attempt before a second AI decision or Discord write") do |http:|
  RequestAcceptance.with_context do |ctx|
    flow = RequestAcceptance::Workflow
    receipt = flow.submit(http)
    flow.configure_policy
    canary = "UPSTREAM-RATE-LIMIT-PRIVATE-DETAIL"
    ctx.expect_github_token
    ctx.transport.expect_json("GET", RequestAcceptance::GITHUB_ISSUES_PATTERN,
                              status: 429, headers: { "Retry-After" => "90" }, body: { "message" => canary })
    ctx.process_runner.enqueue(->(call) { flow.read_answer(call) })

    expect(flow.triage(ctx).call.triaged).to eq(0)
    task = receipt.external_event.reload.task
    expect(task.status).to eq("inbox")
    expect(task.last_error).to eq("Coordination failed (rate_limited)")
    expect(task.next_action_at).to eq(ctx.clock.now + 3600)
    expect(task.coordination_result).to eq(nil)
    expect(ctx.process_runner.calls.size).to eq(1)
    expect(ctx.transport.requests_to(RequestAcceptance::GITHUB_ISSUES_PATTERN, method: "GET").size).to eq(1)
    expect(OutboundAction.count).to eq(0)
    expect(ctx.discord_posts).to eq([])
    expect(EventDelivery.where(kind: "query.failed").exists?).to eq(true)
    expect(flow.event_text.include?(canary)).to eq(false)
    ctx.assert_consumed!
  end
end

test("a partially failed delivery waits for the remaining action without replanning or consuming feedback") do |http:|
  RequestAcceptance.with_context do |ctx|
    flow = RequestAcceptance::Workflow
    receipt = flow.submit(http)
    flow.configure_policy
    ctx.process_runner.enqueue(->(call) do
      flow.result_answer(call, summary: "Two requested notifications", actions: [
        flow.discord_action("First notification"), flow.discord_action("Second notification")
      ])
    end)
    triage = flow.triage(ctx)
    expect(triage.call.triaged).to eq(1)
    task = receipt.external_event.reload.task
    first, second = task.outbound_actions.order(:id).to_a
    expect(task.coordination_result["action_count"]).to eq(2)
    batch = task.delivery_batch_key
    canary = "UPSTREAM-DISCORD-PRIVATE-DETAIL"
    ctx.transport.expect_json("POST", RequestAcceptance::DISCORD_POST_URL,
                              status: 400, body: { "message" => canary })
    ctx.expect_discord_post(external_id: "140000000000000043")
    delivery = Interaction::OutboundService.new(registry: ctx.registry, ai_runner: ctx.runner, clock: ctx.clock)
    expect(delivery.call(first.id).ok).to eq(false)
    expect(first.reload.status).to eq("failed")
    expect(first.error.include?(canary)).to eq(false)
    expect(second.reload.status).to eq("pending")

    reconciler = Coordination::DeliveryReconciler.new(clock: ctx.clock)
    expect(reconciler.reconcile(task_id: task.id).code).to eq(:batch_pending)
    expect(task.reload.status).to eq("waiting_delivery")
    feedback = task.task_feedbacks.create!(body: "Please review the failure.", author: "fixture-operator",
                                          author_type: "human")
    expect(triage.call.triaged).to eq(0)
    expect(feedback.reload.processed?).to eq(false)
    expect(task.reload.delivery_batch_key).to eq(batch)
    expect(task.outbound_actions.count).to eq(2)
    expect(ctx.process_runner.calls.size).to eq(1)

    expect(delivery.call(second.id).ok).to eq(true)
    expect(second.reload.status).to eq("sent")
    expect(task.reload.status).to eq("waiting_delivery")
    expect(reconciler.reconcile(task_id: task.id).code).to eq(:settled_waiting_human)
    expect(task.reload.status).to eq("waiting_human")
    expect(task.last_error).to eq("Delivery requires operator review (delivery_failed)")
    expect(feedback.reload.processed?).to eq(false)
    expect(task.delivery_batch_key).to eq(batch)
    expect(task.outbound_actions.count).to eq(2)
    expect(TaskRun.count).to eq(0)
    expect(ctx.discord_posts.size).to eq(2)
    expect(flow.event_text.include?(canary)).to eq(false)
    ctx.assert_consumed!
  end
end

test("an unconfigured provider remains selectable and records a safe runtime failure") do |http:|
  RequestAcceptance.with_context do |ctx|
    flow = RequestAcceptance::Workflow
    receipt = flow.submit(http)
    policy = flow.configure_policy(provider: "codex")
    expect(policy.persisted?).to eq(true)
    expect(ctx.ai.registry.configured?("codex")).to eq(false)

    expect(flow.triage(ctx).call.triaged).to eq(0)
    task = receipt.external_event.reload.task
    expect(task.last_error).to eq("Coordination failed (provider_not_configured)")
    expect(task.next_action_at).to eq(ctx.clock.now + 3600)
    expect(task.status).to eq("inbox")
    expect(OutboundAction.count).to eq(0)
    expect(ctx.process_runner.calls).to eq([])
    expect(ctx.transport.requests).to eq([])
    expect(flow.api_get(http, receipt.request_id)["last_error"]).to eq(task.last_error)
    http.get("/admin/tasks/#{task.id}", {}, flow.admin_headers)
    expect(http.last_response.status).to eq(200)
    expect(Nokogiri::HTML(http.last_response.body).at_css("#task-last-error").text.include?(task.last_error)).to eq(true)
    ctx.assert_consumed!
  end
end
