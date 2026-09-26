# frozen_string_literal: true

require "db_helper"
require_relative "support/admin_test_support"

test("board shows fixture tasks grouped by status") do |http:|
  inbox = Task.create!(title: "受信タスク", status: "inbox", priority: 1)
  done = Task.create!(title: "完了タスク", status: "done", priority: 9)

  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks"

    expect(http.last_response.status).to eq(200)
    body = http.last_response.body
    expect(body.include?(inbox.title)).to eq(true)
    expect(body.include?(done.title)).to eq(true)
    expect(body.include?("受信箱")).to eq(true)
    expect(body.include?("完了")).to eq(true)
  end
end

test("board escapes untrusted task titles") do |http:|
  Task.create!(title: %(<script>alert("board")</script>), status: "inbox")

  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks"

    body = http.last_response.body
    expect(body.include?(%(<script>alert("board")</script>))).to eq(false)
    expect(body.include?("&lt;script&gt;")).to eq(true)
  end
end

test("task detail shows feedback and run history") do |http:|
  task = Task.create!(title: "詳細タスク", status: "running", priority: 3,
                      description: "やること")
  task.task_feedbacks.create!(body: "もっと急いで", author: "運用者", author_type: "human")
  task.task_runs.create!(provider: "codex", model: "m", effort: "high", status: "succeeded")

  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks/#{task.id}"

    expect(http.last_response.status).to eq(200)
    body = http.last_response.body
    expect(body.include?("詳細タスク")).to eq(true)
    expect(body.include?("もっと急いで")).to eq(true)
    expect(body.include?("運用者")).to eq(true)
    expect(body.include?("codex")).to eq(true)
  end
end

test("task detail escapes feedback and descriptions") do |http:|
  task = Task.create!(title: "X", status: "inbox",
                      description: %(<img src=x onerror=alert(1)>))
  task.task_feedbacks.create!(body: %(<b>太字</b><script>alert(2)</script>), author: "a", author_type: "human")

  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks/#{task.id}"

    body = http.last_response.body
    expect(body.include?("<script>alert(2)</script>")).to eq(false)
    expect(body.include?("<img src=x onerror=alert(1)>")).to eq(false)
    expect(body.include?("&lt;script&gt;")).to eq(true)
  end
end

test("task detail exposes no worker run button") do |http:|
  task = Task.create!(title: "Y", status: "ready")

  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks/#{task.id}"

    body = http.last_response.body.downcase
    expect(body.include?("run-now")).to eq(false)
    expect(body.include?("今すぐ実行")).to eq(false)
    expect(body.include?("ワーカー実行")).to eq(false)
  end
end

test("task detail shows run error codes and outbound actions without resend") do |http:|
  task = Task.create!(title: "OUT", status: "running")
  task.task_runs.create!(provider: "muse", status: "failed",
                         error_code: "provider_not_configured", error: "CLI がありません")
  task.outbound_actions.create!(plugin: "github", operation: "reply",
                                idempotency_key: "idem-1", status: "uncertain",
                                error_code: "ambiguous_send", error: "結果不明")

  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks/#{task.id}"

    expect(http.last_response.status).to eq(200)
    body = http.last_response.body
    expect(body.include?("provider_not_configured")).to eq(true)
    expect(body.include?("未確定")).to eq(true)
    expect(body.include?("uncertain")).to eq(true)
    expect(body.include?("ambiguous_send")).to eq(true)
    expect(body.include?("再送する")).to eq(false)
    expect(body.include?("outbound")).to eq(false)
  end
end

test("unknown task redirects to board") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks/99999999"

    expect(http.last_response.status).to eq(302)
    http.follow_redirect!
    expect(http.last_response.body.include?("タスクボード")).to eq(true)
  end
end

test("task detail exposes escaped work plan and structured result fields only") do |http:|
  work_plan = "Confirm the fix\n<img src=x onerror=alert('plan')>"
  outcome = "<script>alert('outcome')</script>"
  summary = "The regression is fixed\n<script>alert('summary')</script>"
  task = Task.create!(title: "レビュー対象", status: "waiting_review", work_plan: work_plan)
  run = task.task_runs.create!(provider: "codex", status: "succeeded",
                              instructions: "PRIVATE-PROMPT-MARKER",
                              result: { "outcome" => outcome, "summary" => summary,
                                        "stdout" => "PRIVATE-STDOUT-MARKER", "prompt" => "PRIVATE-RESULT-PROMPT" })

  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks/#{task.id}"
    expect(http.last_response.status).to eq(200)
    document = Nokogiri::HTML(http.last_response.body)
    result = document.at_css("#run-result-#{run.id}")
    expect(result.text.include?(outcome)).to eq(true)
    expect(result.at_css(".admin-verbatim").text).to eq(summary)
    plan = document.at_xpath("//tr[th[text()='作業計画']]/td/div")
    expect(plan.text).to eq(work_plan)
    expect(result.css("script, img").empty?).to eq(true)
    expect(plan.css("script, img").empty?).to eq(true)
    %w[PRIVATE-PROMPT-MARKER PRIVATE-STDOUT-MARKER PRIVATE-RESULT-PROMPT].each do |private_text|
      expect(http.last_response.body.include?(private_text)).to eq(false)
    end
  end
end

test("task detail handles absent or malformed result fields without exposing arbitrary output") do |http:|
  task = Task.create!(title: "結果待ち", status: "waiting_review")
  nil_result = task.task_runs.create!(provider: "codex", status: "failed")
  malformed = task.task_runs.create!(provider: "codex", status: "failed",
                                    result: { "summary" => { "stdout" => "DO-NOT-RENDER" } })
  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks/#{task.id}"
    expect(http.last_response.status).to eq(200)
    document = Nokogiri::HTML(http.last_response.body)
    [nil_result, malformed].each do |run|
      expect(document.at_css("#run-result-#{run.id}").text.include?("構造化された実行結果はまだありません")).to eq(true)
    end
    expect(http.last_response.body.include?("DO-NOT-RENDER")).to eq(false)
  end
end

test("board pagination reaches tasks beyond the former 200 row limit with stable ties") do |http:|
  timestamp = Time.utc(2026, 1, 1)
  ids = Task.insert_all!(205.times.map do |index|
    { title: "履歴タスク #{index}", status: "done", priority: 4, created_at: timestamp, updated_at: timestamp }
  end).rows.flatten

  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks", status: "done"
    visited = []
    5.times do |page|
      expect(http.last_response.status).to eq(200)
      document = Nokogiri::HTML(http.last_response.body)
      links = document.css(".admin-task-card a")
      expect(links.size).to eq(page == 4 ? 5 : 50)
      visited.concat(links.map { |link| link["href"].split("/").last.to_i })
      expect(document.at_css("[aria-current=page]").text).to eq("#{page + 1} / 5ページ")
      next_page = document.at_css("a[rel=next]")
      if page < 4
        expect(next_page["href"].include?("status=done")).to eq(true)
        http.get next_page["href"]
      else
        expect(next_page).to eq(nil)
        expect(document.at_css("a[rel=prev]").nil?).to eq(false)
      end
    end
    expect(visited).to eq(ids.reverse)
    expect(visited.uniq.size).to eq(205)
  end
end

test("board status filter excludes other states and keeps its selection") do |http:|
  selected = Task.create!(title: "人間の確認を待つ", status: "waiting_human")
  hidden = Task.create!(title: "すでに完了", status: "done", priority: 100)
  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks", status: "waiting_human"
    document = Nokogiri::HTML(http.last_response.body)
    expect(document.css(".admin-task-card a").map(&:text)).to eq([selected.title])
    expect(http.last_response.body.include?(hidden.title)).to eq(false)
    expect(document.at_css("select[name=status] option[selected]")["value"]).to eq("waiting_human")
    expect(document.css(".admin-column").size).to eq(1)
  end
end

test("board rejects malformed filters and page numbers safely and clamps pages beyond the end") do |http:|
  timestamp = Time.utc(2026, 1, 1)
  ids = Task.insert_all!(51.times.map do |index|
    { title: "安全なページ #{index}", status: "inbox", priority: 0, created_at: timestamp, updated_at: timestamp }
  end).rows.flatten
  AdminTestSupport.as_admin(http) do
    ["0", "-1", "abc", "1.5", "999999999999999999", ["2"], { "nested" => "2" }].each do |page|
      http.get "/admin/tasks", page: page, status: "<script>invalid</script>"
      expect(http.last_response.status).to eq(200)
      document = Nokogiri::HTML(http.last_response.body)
      expect(document.at_css("[aria-current=page]").text).to eq("1 / 2ページ")
      expect(document.css(".admin-task-card a").map { |link| link["href"].split("/").last.to_i }).to eq(ids.reverse.first(50))
      expect(http.last_response.body.include?("<script>invalid</script>")).to eq(false)
    end
    http.get "/admin/tasks", page: "999", status: ["inbox"]
    document = Nokogiri::HTML(http.last_response.body)
    expect(http.last_response.status).to eq(200)
    expect(document.at_css("[aria-current=page]").text).to eq("2 / 2ページ")
    expect(document.css(".admin-task-card a").map { |link| link["href"].split("/").last.to_i }).to eq([ids.first])
  end
end
