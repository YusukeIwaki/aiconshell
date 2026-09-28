# frozen_string_literal: true

require "db_helper"
require_relative "support/admin_test_support"

test("unauthenticated admin GET routes all return 401") do |http:|
  AdminTestSupport.as_anonymous(http) do
    %w[
      /admin
      /admin/tasks
      /admin/tasks/1
      /admin/layer_policies
      /admin/layer_policies/coordination/edit
      /admin/accounts
      /admin/event_logs
    ].each do |path|
      http.get path
      expect(http.last_response.status).to eq(401)
    end
  end
end

test("unauthenticated admin POST/PATCH routes return 401") do |http:|
  AdminTestSupport.as_anonymous(http) do
    http.post "/admin/tasks/1/feedbacks", { task_feedback: { body: "x" } }
    expect(http.last_response.status).to eq(401)

    http.patch "/admin/layer_policies/coordination", { layer_policy: { provider: "codex" } }
    expect(http.last_response.status).to eq(401)
  end
end

test("wrong password returns 401") do |http:|
  AdminTestSupport.with_env(AdminTestSupport::USERNAME, AdminTestSupport::PASSWORD) do
    http.header "Host", AdminTestSupport::HOST
    http.basic_authorize AdminTestSupport::USERNAME, "wrong-password"
    http.get "/admin/tasks"
    expect(http.last_response.status).to eq(401)
  end
end

test("fail closed: unset credentials deny even correct auth") do |http:|
  AdminTestSupport.with_env(nil, nil) do
    http.header "Host", AdminTestSupport::HOST
    http.basic_authorize "anything", "anything"
    http.get "/admin/tasks"
    expect(http.last_response.status).to eq(401)
  end
end

test("fail closed: blank password denies all") do |http:|
  AdminTestSupport.with_env(AdminTestSupport::USERNAME, "") do
    http.header "Host", AdminTestSupport::HOST
    http.basic_authorize AdminTestSupport::USERNAME, ""
    http.get "/admin/accounts"
    expect(http.last_response.status).to eq(401)
  end
end

test("authenticated admin pages return 200") do |http:|
  AdminTestSupport.as_admin(http) do
    %w[
      /admin
      /admin/tasks
      /admin/layer_policies
      /admin/layer_policies/coordination/edit
      /admin/accounts
      /admin/event_logs
    ].each do |path|
      http.get path
      expect(http.last_response.status).to eq(200)
    end
  end
end

test("authenticated pages carry no credential values") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/tasks"
    body = http.last_response.body
    expect(body.include?(AdminTestSupport::PASSWORD)).to eq(false)
    expect(body.include?("ADMIN_PASSWORD")).to eq(false)
  end
end
