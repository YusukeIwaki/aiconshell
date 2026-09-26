# frozen_string_literal: true

require "db_helper"
require_relative "support/admin_test_support"

test("feedback post stores information for Coordination") do |http:|
  task = Task.create!(title: "FB", status: "inbox", priority: 2)

  AdminTestSupport.as_admin(http) do
    http.post "/admin/tasks/#{task.id}/feedbacks",
      { task_feedback: { body: "来週までに", author: "運用者" } }

    expect(http.last_response.status).to eq(302)
    feedback = TaskFeedback.last
    expect(feedback.task_id).to eq(task.id)
    expect(feedback.body).to eq("来週までに")
    expect(feedback.author).to eq("運用者")
    expect(task.reload.status).to eq("inbox")
    expect(task.priority).to eq(2)
  end
end

test("feedback ignores smuggled state/priority/run payloads") do |http:|
  task = Task.create!(title: "FB2", status: "inbox", priority: 2)
  other = Task.create!(title: "other", status: "ready", priority: 5)

  AdminTestSupport.as_admin(http) do
    http.post "/admin/tasks/#{task.id}/feedbacks",
      {
        task_feedback: {
          body: "本文", author: "a",
          status: "done", priority: 999, task_id: other.id,
          processed_at: Time.utc(2026, 1, 1).iso8601
        },
        status: "done", priority: 999
      }

    expect(http.last_response.status).to eq(302)
    feedback = TaskFeedback.last
    expect(feedback.task_id).to eq(task.id)
    expect(task.reload.status).to eq("inbox")
    expect(task.priority).to eq(2)
    expect(other.reload.status).to eq("ready")
    expect(TaskRun.count).to eq(0)
  end
end

test("feedback validation failure redirects with message") do |http:|
  task = Task.create!(title: "FB3", status: "inbox")

  AdminTestSupport.as_admin(http) do
    http.post "/admin/tasks/#{task.id}/feedbacks",
      { task_feedback: { body: "", author: "a" } }

    expect(http.last_response.status).to eq(302)
    expect(TaskFeedback.count).to eq(0)
    http.follow_redirect!
    expect(http.last_response.status).to eq(200)
  end
end

test("feedback to unknown task redirects to board") do |http:|
  AdminTestSupport.as_admin(http) do
    http.post "/admin/tasks/99999999/feedbacks",
      { task_feedback: { body: "x" } }

    expect(http.last_response.status).to eq(302)
    expect(TaskFeedback.count).to eq(0)
  end
end

test("CSRF: POST without token is rejected") do |http:|
  task = Task.create!(title: "CSRF", status: "inbox")

  AdminTestSupport.as_admin(http) do
    AdminTestSupport.with_forgery_protection do
      http.post "/admin/tasks/#{task.id}/feedbacks",
        { task_feedback: { body: "forged" } }

      expect(http.last_response.status).to eq(422)
      expect(TaskFeedback.count).to eq(0)
    end
  end
end

test("CSRF: POST with form token succeeds") do |http:|
  task = Task.create!(title: "CSRF2", status: "inbox")

  AdminTestSupport.as_admin(http) do
    AdminTestSupport.with_forgery_protection do
      http.get "/admin/tasks/#{task.id}"
      token = http.last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
      expect(token.nil?).to eq(false)

      http.post "/admin/tasks/#{task.id}/feedbacks",
        { task_feedback: { body: "正規", author: "a" }, authenticity_token: token }

      expect(http.last_response.status).to eq(302)
      expect(TaskFeedback.count).to eq(1)
    end
  end
end
