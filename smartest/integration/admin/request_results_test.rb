# frozen_string_literal: true

require "db_helper"
require_relative "support/admin_test_support"
require_relative "support/task_request_test_support"

test("waiting delivery is a distinct Japanese board column and filter") do |http:|
  task = Task.create!(title: "配送確認を待つ依頼", status: "waiting_delivery")
  Task.create!(title: "完了済みの依頼", status: "done")
  AdminTestSupport.as_admin(http) do
    http.get("/admin/tasks", status: "waiting_delivery")
    expect(http.last_response.status).to eq(200)
    document = Nokogiri::HTML(http.last_response.body)
    expect(document.css(".admin-task-card a").map(&:text)).to eq([task.title])
    expect(document.at_css("select[name=status] option[selected]")["value"]).to eq("waiting_delivery")
    expect(document.at_css("select[name=status] option[selected]").text).to eq("配送待ち")
    expect(document.css(".admin-column").size).to eq(1)
  end
end

test("task detail shows escaped coordination summary and error without arbitrary stored output") do |http:|
  summary = "調査結果\n<script>summary()</script>"
  error = "Coordination failed (provider_not_configured)\n<img src=x onerror=error()>"
  task = Task.create!(
    title: "管理依頼", status: "waiting_delivery", last_error: error,
    coordination_result: { "summary" => summary, "action_count" => 1,
                           "stdout" => "PRIVATE-COORDINATION-STDOUT", "prompt" => "PRIVATE-COORDINATION-PROMPT" }
  )
  AdminTestSupport.as_admin(http) do
    http.get("/admin/tasks/#{task.id}")
    expect(http.last_response.status).to eq(200)
    document = Nokogiri::HTML(http.last_response.body)
    result = document.at_css("#coordination-result")
    expect(result.at_css(".admin-verbatim").text).to eq(summary)
    expect(result.text.include?("通知件数：1件")).to eq(true)
    expect(result.text.include?("通知の配送を待っています")).to eq(true)
    expect(result.css("script, img").empty?).to eq(true)
    error_row = document.at_css("#task-last-error")
    expect(error_row.at_css(".admin-verbatim").text).to eq(error)
    expect(error_row.css("script, img").empty?).to eq(true)
    %w[PRIVATE-COORDINATION-STDOUT PRIVATE-COORDINATION-PROMPT].each do |private_text|
      expect(http.last_response.body.include?(private_text)).to eq(false)
    end
  end
end

test("task detail handles missing or malformed coordination summaries without dumping JSON") do |http:|
  task = Task.create!(title: "結果待ち", status: "inbox",
                      coordination_result: { "summary" => { "stdout" => "DO-NOT-SHOW" }, "action_count" => 0 })
  AdminTestSupport.as_admin(http) do
    [task.coordination_result, nil].each do |stored|
      task.update!(coordination_result: stored)
      http.get("/admin/tasks/#{task.id}")
      expect(http.last_response.status).to eq(200)
      expect(Nokogiri::HTML(http.last_response.body).at_css("#coordination-result")).to eq(nil)
      expect(http.last_response.body.include?("DO-NOT-SHOW")).to eq(false)
    end
  end
end

test("authenticated API receipts publish only six fields and selected result data") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    TaskRequestTestSupport.api_post(http, { title: "結果の確認", description: "公開要約を読む" }, key: "result-fields")
    expect(http.last_response.status).to eq(202)
    accepted = JSON.parse(http.last_response.body)
    keys = %w[request_id status task_id task_status coordination_result last_error].sort
    expect(accepted.keys.sort).to eq(keys)
    expect(accepted.slice("task_id", "task_status", "coordination_result", "last_error")).to eq({
      "task_id" => nil, "task_status" => nil, "coordination_result" => nil, "last_error" => nil
    })
    receipt = TaskRequest.find_by!(request_id: accepted.fetch("request_id"))
    task = Task.create!(
      title: "結果", status: "waiting_human", last_error: "Delivery requires operator review (delivery_uncertain)",
      coordination_result: { "summary" => "配送の確認が必要です", "action_count" => 1,
                             "stdout" => "PRIVATE-RAW-OUTPUT", "prompt" => "PRIVATE-PROMPT" }
    )
    receipt.external_event.update!(task: task, processed_at: Time.current)
    TaskRequestTestSupport.api_get(http, receipt.request_id)
    expect(http.last_response.status).to eq(200)
    processed = JSON.parse(http.last_response.body)
    expect(processed.keys.sort).to eq(keys)
    expect(processed.slice("status", "task_id", "task_status")).to eq({
      "status" => "processed", "task_id" => task.id, "task_status" => "waiting_human"
    })
    expect(processed["coordination_result"]).to eq({ "summary" => "配送の確認が必要です", "action_count" => 1 })
    expect(processed["coordination_result"].keys.sort).to eq(%w[action_count summary])
    expect(processed["last_error"]).to eq(task.last_error)
    expect(http.last_response.body.include?("PRIVATE-")).to eq(false)

    TaskRequestTestSupport.api_get(http, receipt.request_id, token: nil)
    expect(http.last_response.status).to eq(401)
    expect(http.last_response.body.include?("配送の確認")).to eq(false)
  end
end

test("API receipt suppresses malformed coordination result values") do |http:|
  TaskRequestTestSupport.with_api_token(TaskRequestTestSupport::API_TOKEN) do
    TaskRequestTestSupport.api_post(http, { title: "結果", description: "型の確認" }, key: "malformed-result")
    receipt = TaskRequest.find_by!(request_id: JSON.parse(http.last_response.body).fetch("request_id"))
    task = Task.create!(title: "結果", status: "inbox")
    receipt.external_event.update!(task: task, processed_at: Time.current)
    [
      { "summary" => { "stdout" => "PRIVATE-RAW-OUTPUT" }, "action_count" => 1 },
      { "summary" => "valid text", "action_count" => "1" },
      { "summary" => "valid text", "action_count" => -1 },
      ["PRIVATE-RAW-OUTPUT"],
      nil
    ].each do |stored|
      task.update!(coordination_result: stored)
      TaskRequestTestSupport.api_get(http, receipt.request_id)
      expect(http.last_response.status).to eq(200)
      expect(JSON.parse(http.last_response.body)["coordination_result"]).to eq(nil)
      expect(http.last_response.body.include?("PRIVATE-RAW-OUTPUT")).to eq(false)
    end
  end
end
