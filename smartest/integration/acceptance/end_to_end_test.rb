# frozen_string_literal: true

require_relative "acceptance_helper"

# Bounded issue-9 acceptance slice: one human GitHub issue flows through the
# real layers against real PostgreSQL tables and the real Solid Queue tables.
#
# Real under test: plugin Registry + Github adapter (scripted HTTP only),
# Ai::Runner + ProcessRunner subprocess (temporary fake `claude` executable
# only), Interaction / Coordination / Execution services, all shared tables,
# and the real WorkflowEvents/EventLog boot wiring (every lifecycle emit
# actually persists as an EventDelivery row, asserted below).
# Fake at the boundary: HTTP transport and the `claude` executable only.
#
# This is NOT real AI-account verification: no subscription login, no model
# call, no external posting. See docs/verification.md.
test("human issue flows from poll to schema-validated external reply") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_acceptance_env do |ctx|
    ensure_real_eventlog_wiring!
    canary = ENV.fetch("ACCEPTANCE_CANARY_SECRET")
    stub_github_flow(ctx, canary: canary)

    # 1. Poll normalizes the human issue through the real Github adapter.
    poll = Interaction::PollService.new(registry: ctx.registry, event_sink: ctx.sink)
      .call(plugin: "github", scope: AcceptanceHelper::SCOPE)
    expect(poll.ok).to eq(true)
    expect(poll.code).to eq(:ok)
    issue_event = ExternalEvent.find_by(event_type: "github.issue")
    expect(issue_event.actor_type).to eq("human")
    expect(issue_event.resource_id).to eq("issue:o/r#1")
    expect(issue_event.task).to eq(nil)
    # The adapter's own auth + resource request shapes reached the transport:
    # installation-token exchange, issues, repository comments, and runs.
    # Exact per-poll request counts are the plugin lane's business (paging
    # can legitimately add requests), so this slice asserts the meaningful
    # behavior: auth happened, the fetched token was actually used, and
    # each resource family was listed.
    token_posts = ctx.transport.requests_to("#{AcceptanceHelper::GH_API}/app/installations/789/access_tokens")
    expect(token_posts.empty?).to eq(false)
    expect(token_posts.all? { |entry| entry[:method] == "POST" }).to eq(true)
    list_hits = ctx.transport.requests_to(%r{/repos/o/r/issues\?})
    expect(list_hits.empty?).to eq(false)
    expect(list_hits.all? do |entry|
      entry[:headers]["Authorization"] == "Bearer #{AcceptanceHelper::FAKE_INSTALLATION_TOKEN}"
    end).to eq(true)
    expect(ctx.transport.requests_to(%r{/repos/o/r/issues/comments\?}).empty?).to eq(false)
    expect(ctx.transport.requests_to(%r{/repos/o/r/pulls/comments\?}).empty?).to eq(false)
    expect(ctx.transport.requests_to(%r{/repos/o/r/actions/runs}).empty?).to eq(false)

    # 2. Ingest creates the inbox task without any AI call yet.
    triage = Coordination::TriageService.new(ai_runner: ctx.ai_runner, event_sink: ctx.sink)
    first = triage.call
    expect(first.ingested).to eq(2)
    expect(first.triaged).to eq(0)
    task = Task.last
    expect(task.status).to eq("inbox")
    expect(task.source_plugin).to eq("github")
    expect(task.source_resource_id).to eq("issue:o/r#1")
    expect(cli_evidence(ctx.evidence_path).size).to eq(0)

    # 3. A human follow-up comment attaches immutable clarification via ingest.
    listed_before = ctx.transport.requests_to(%r{/repos/o/r/issues\?}).size
    second_poll = Interaction::PollService.new(registry: ctx.registry, event_sink: ctx.sink)
      .call(plugin: "github", scope: AcceptanceHelper::SCOPE)
    expect(second_poll.ok).to eq(true)
    expect(ctx.transport.requests_to(%r{/repos/o/r/issues\?}).size > listed_before).to eq(true)
    second = triage.call
    expect(second.ingested).to eq(1)
    expect(ExternalEvent.where(event_type: "github.issue").count).to eq(1)
    clarification_ids = task.task_feedbacks.where(author_type: "human").order(:id).pluck(:id)
    expect(clarification_ids.empty?).to eq(false)
    expect(task.task_feedbacks.unprocessed.count).to eq(clarification_ids.size)
    expect(task.task_feedbacks.pluck(:body).any? { |body| body.include?("only affects Safari") }).to eq(true)
    expect(task.task_feedbacks.pluck(:body).any? { |body| body.include?("still broken after deploy") }).to eq(true)

    # 4. Structured coordination triage dispatches through the real AI runner.
    %w[coordination execution interaction].each do |layer|
      LayerPolicy.create!(layer: layer, provider: "claude", enabled: true)
    end
    queue_before = SolidQueue::Job.where(class_name: "ExecutionRunJob").count
    decided = triage.call
    expect(decided.triaged).to eq(1)
    task.reload
    expect(task.status).to eq("running")
    expect(task.priority).to eq(10)
    run = task.task_runs.order(:id).last
    expect(run.status).to eq("pending")
    expect(run.provider).to eq("claude")
    expect(run.work_snapshot["feedback"].map { |entry| entry["id"] }.sort).to eq(clarification_ids.sort)
    expect(SolidQueue::Job.where(class_name: "ExecutionRunJob").count).to eq(queue_before + 1)
    job = SolidQueue::Job.where(class_name: "ExecutionRunJob").order(:id).last
    expect(job.queue_name).to eq("execution")
    expect(job.arguments["arguments"]).to eq([run.id])

    # 5. Execution consumes the immutable dispatch snapshot in its workspace,
    # even though a late clarification arrives after dispatch.
    late = TaskFeedback.create!(task: task, body: "late instruction: rewrite everything",
                                author: "alice", author_type: "human")
    snapshot_before = TaskRun.find(run.id).work_snapshot
    exec_result = Execution::RunnerService.new(ai_runner: ctx.ai_runner, event_sink: ctx.sink).call(run.id)
    expect(exec_result.ok).to eq(true)
    run.reload
    task.reload
    expect(run.status).to eq("succeeded")
    expect(run.result["outcome"]).to eq("waiting_review")
    expect(task.status).to eq("waiting_review")
    expect(TaskRun.find(run.id).work_snapshot).to eq(snapshot_before)
    workspace = File.join(ctx.execution_root, "task_#{task.id}", "run_#{run.id}")
    expect(Dir.exist?(workspace)).to eq(true)
    execution_call = cli_evidence(ctx.evidence_path).find { |call| call["stdin"].include?("Execute this persisted work request") }
    expect(execution_call.nil?).to eq(false)
    expect(execution_call["cwd"]).to eq(File.realpath(workspace))
    clarification_ids.each do |id|
      expect(execution_call["stdin"].include?("\"id\":#{id},")).to eq(true)
    end
    expect(execution_call["stdin"].include?("\"id\":#{late.id},")).to eq(false)
    expect(execution_call["stdin"].include?("rewrite everything")).to eq(false)
    expect(execution_call["stdin"].include?("only affects Safari")).to eq(true)
    expect(execution_call["stdin"].include?("please fix the login bug")).to eq(true)

    # 6. Completion persisted the outbound intent; interaction delivers it
    # through the real registry with schema validation on both sides.
    action = OutboundAction.order(:id).last
    expect(action.status).to eq("pending")
    expect(action.plugin).to eq("github")
    expect(action.operation).to eq("reply")
    expect(action.input["resource_id"]).to eq("issue:o/r#1")
    delivery = Interaction::OutboundService.new(registry: ctx.registry, ai_runner: ctx.ai_runner,
                                                event_sink: ctx.sink).call(action.id)
    expect(delivery.ok).to eq(true)
    action.reload
    expect(action.status).to eq("sent")
    expect(action.external_id).to eq("555")
    replies = ctx.transport.requests_to(%r{/repos/o/r/issues/1/comments}).select { |entry| entry[:method] == "POST" }
    expect(replies.size).to eq(1)
    # The wire request carries resource_id in the URL path and body in the
    # payload; together they must form the schema-valid reply input that the
    # real registry validated before any I/O.
    wire = replies.first
    target = %r{/repos/(?<repo>[^/]+/[^/]+)/issues/(?<number>\d+)/comments}.match(wire[:url])
    expect(target.nil?).to eq(false)
    sent_body = JSON.parse(wire[:body])
    reply_input = { "resource_id" => "issue:#{target[:repo]}##{target[:number]}",
                    "body" => sent_body["body"] }
    expect(JSONSchemer.schema(Aiconshell::Plugins::Schemas::REPLY_INPUT).valid?(reply_input)).to eq(true)
    expect(reply_input["resource_id"]).to eq("issue:o/r#1")
    expect(sent_body["body"].start_with?("drafted: ")).to eq(true)
    expect(sent_body["body"].include?("Login retry fixed")).to eq(true)

    # 7. Every layer ran through a real child process with a controlled
    # environment: prompts on stdin (never argv), no inherited secrets.
    calls = cli_evidence(ctx.evidence_path)
    expect(calls.size).to eq(3)
    expect(calls.map { |call| call["pid"] }.uniq.size).to eq(3)
    expect(calls.all? { |call| call["pid"] != Process.pid }).to eq(true)
    expect(calls.map { |call| call["program"] }.all? { |program| program.end_with?("/bin/claude") }).to eq(true)
    markers = ["You coordinate tasks", "Execute this persisted work request", "Draft a concise reply"]
    expect(markers.all? { |marker| calls.any? { |call| call["stdin"].include?(marker) } }).to eq(true)
    calls.each do |call|
      joined = call["argv"].join("\n")
      expect(markers.any? { |marker| joined.include?(marker) }).to eq(false)
      expect(call["env"]["CLAUDE_CONFIG_DIR"]).to eq(ctx.claude_home)
      %w[TEST_DATABASE_URL DATABASE_URL GITHUB_PRIVATE_KEY GITHUB_APP_ID
         GITHUB_INSTALLATION_ID ACCEPTANCE_CANARY_SECRET].each do |secret|
        expect(call["env"].key?(secret)).to eq(false)
      end
    end

    # 8. Every layer emitted structured lifecycle events through the REAL
    # EventLog path: each forwarded emit returned a persisted envelope, and
    # every one of those envelopes is actually present as an EventDelivery
    # row in PostgreSQL. This proves persistence, not mirroring: the
    # wrapper's in-memory record alone would satisfy none of the row
    # assertions below.
    expected_kinds = %w[poll.completed triage.ingested triage.completed dispatch.created
                        run.leased run.completed outbound.sent]
    expected_kinds.each do |kind|
      expect(ctx.sink.kinds.include?(kind)).to eq(true)
    end
    expect(ctx.sink.kinds.any? { |kind| kind.end_with?(".failed") || kind == "triage.ai_failed" }).to eq(false)
    expect(ctx.sink.forwarded.empty?).to eq(false)
    expect(ctx.sink.forwarded.all? { |envelope| envelope.is_a?(Hash) && envelope["event_id"] }).to eq(true)
    persisted_ids = EventDelivery.pluck(:event_id)
    ctx.sink.forwarded.each do |envelope|
      expect(persisted_ids.include?(envelope["event_id"])).to eq(true)
    end
    expect(EventDelivery.count).to eq(ctx.sink.forwarded.size)
    expect(EventDelivery.distinct.pluck(:layer).sort).to eq(%w[coordination execution interaction])
    expected_kinds.each do |kind|
      expect(EventDelivery.where(kind: kind).exists?).to eq(true)
    end
    expect(EventDelivery.where("kind LIKE '%.failed'").or(EventDelivery.where(kind: "triage.ai_failed")).exists?).to eq(false)
    # Row/column integrity: each persisted row carries its own envelope with
    # matching identity columns.
    EventDelivery.find_each do |row|
      expect(row.envelope["event_id"]).to eq(row.event_id)
      expect(row.envelope["layer"]).to eq(row.layer)
      expect(row.envelope["kind"]).to eq(row.kind)
      expect(row.occurred_at.nil?).to eq(false)
    end

    # 9. No persisted envelope leaks the injected canary, the fetched
    # installation token, raw CLI stdout, or AI prompts. The canary was
    # planted in ENV and inside the untrusted issue title and comment.
    # It therefore travelled through ExternalEvent payloads, Task
    # title/description, TaskFeedback, and AI prompt stdin (asserted
    # present there, so its absence below is meaningful rather than
    # vacuous); none of it may land in the EventLog.
    expect(calls.any? { |call| call["stdin"].include?(canary) }).to eq(true)
    forbidden = [canary, AcceptanceHelper::FAKE_INSTALLATION_TOKEN,
                 "You coordinate tasks", "Execute this persisted work request",
                 "Draft a concise reply", '"structured_output"', '"subtype":"success"']
    EventDelivery.find_each do |row|
      serialized = JSON.generate(row.envelope)
      forbidden.each do |fragment|
        expect(serialized.include?(fragment)).to eq(false)
      end
    end
  end
end

# Exact scripted HTTP surface for this slice. No request leaves the process;
# every URL below is served by the ScriptedTransport, including independent
# repository-wide comment streams used by the resumable reconciliation scan.
def stub_github_flow(ctx, canary:)
  helper = self
  ctx.transport.stub_json("POST", "#{AcceptanceHelper::GH_API}/app/installations/789/access_tokens",
                          body: { "token" => AcceptanceHelper::FAKE_INSTALLATION_TOKEN,
                                  "expires_at" => "2030-01-01T00:00:00Z" })
  issue_calls = 0
  ctx.transport.stub_proc("GET", %r{/repos/o/r/issues\?}) do |_entry|
    issue_calls += 1
    updated = issue_calls == 1 ? "2026-09-26T12:01:00Z" : "2026-09-26T12:10:00Z"
    Aiconshell::Plugins::Http::Response.new(
      status: 200, headers: {},
      body: JSON.generate([helper.github_issue(number: 1, updated: updated,
                                               title: "Login fails on retry (ref #{canary})",
                                               body: "please fix the login bug")])
    )
  end
  comment_calls = 0
  ctx.transport.stub_proc("GET", %r{/repos/o/r/issues/comments\?}) do |_entry|
    comment_calls += 1
    comments = [
      helper.github_comment(id: 101, body: "clarification: only affects Safari",
                            updated: "2026-09-26T12:04:00Z")
    ]
    if comment_calls > 1
      comments << helper.github_comment(id: 102, body: "still broken after deploy (ref #{canary})",
                                        updated: "2026-09-26T12:09:00Z")
    end
    Aiconshell::Plugins::Http::Response.new(
      status: 200, headers: {}, body: JSON.generate(comments)
    )
  end
  ctx.transport.stub_json("GET", %r{/repos/o/r/pulls/comments\?}, body: [])
  ctx.transport.stub_json("GET", %r{/repos/o/r/actions/runs}, body: { "workflow_runs" => [] })
  ctx.transport.stub_json("POST", %r{/repos/o/r/issues/1/comments},
                          body: { "id" => 555, "html_url" => "https://github.com/o/r/issues/1#c555" })
end
