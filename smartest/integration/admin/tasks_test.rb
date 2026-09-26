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
  task.feedbacks.create!(body: "もっと急いで", author: "運用者")
  task.runs.create!(provider: "codex", model: "m", effort: "high", status: "succeeded")

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
  task.feedbacks.create!(body: %(<b>太字</b><script>alert(2)</script>), author: "a")

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

test("unknown task redirects to board") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks/99999999"

    expect(http.last_response.status).to eq(302)
    http.follow_redirect!
    expect(http.last_response.body.include?("タスクボード")).to eq(true)
  end
end
