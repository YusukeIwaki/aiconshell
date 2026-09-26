# frozen_string_literal: true

require "db_helper"
require_relative "support/admin_test_support"

test("event log page renders a search form without querying") do |http:|
  AdminTestSupport.as_admin(http) do
    fake = AdminTestSupport::FakeSearchBackend.new(AdminTestSupport.sample_events)
    Admin::EventLogSearch.backend = fake
    http.get "/admin/event_logs"

    expect(http.last_response.status).to eq(200)
    expect(fake.calls).to eq([])
    expect(http.last_response.body.include?("キーワード")).to eq(true)
  end
end

test("search passes validated filters to the backend") do |http:|
  AdminTestSupport.as_admin(http) do
    fake = AdminTestSupport::FakeSearchBackend.new(AdminTestSupport.sample_events)
    Admin::EventLogSearch.backend = fake
    http.get "/admin/event_logs", { search: {
      query: "優先度", layer: "coordination", kind: "task.prioritized",
      task_id: "7", correlation_id: "corr-1",
      since: "2026-09-01T00:00:00Z", until: "2026-09-27T00:00:00Z", limit: "25"
    } }

    expect(http.last_response.status).to eq(200)
    expect(fake.calls.length).to eq(1)
    call = fake.calls.first
    expect(call[:query]).to eq("優先度")
    expect(call[:layer]).to eq("coordination")
    expect(call[:kind]).to eq("task.prioritized")
    expect(call[:task_id]).to eq(7)
    expect(call[:correlation_id]).to eq("corr-1")
    expect(call[:limit]).to eq(25)
    expect(http.last_response.body.include?("優先度を更新しました")).to eq(true)
  end
end

test("search escapes untrusted event content") do |http:|
  evil = [{
    "event_id" => "evt-evil", "layer" => "interaction", "kind" => "ingest",
    "message" => %(<script>alert("evt")</script>), "task_id" => nil,
    "correlation_id" => nil, "occurred_at" => "2026-09-26T10:00:00Z",
    "data" => { "note" => %(<img src=x onerror=alert(3)>) }, "version" => 1
  }]

  AdminTestSupport.as_admin(http) do
    Admin::EventLogSearch.backend = AdminTestSupport::FakeSearchBackend.new(evil)
    http.get "/admin/event_logs", { search: { query: "x" } }

    body = http.last_response.body
    expect(body.include?(%(<script>alert("evt")</script>))).to eq(false)
    expect(body.include?("<img src=x onerror=alert(3)>")).to eq(false)
    expect(body.include?("&lt;script&gt;")).to eq(true)
  end
end

test("invalid filters show errors and never reach the backend") do |http:|
  AdminTestSupport.as_admin(http) do
    fake = AdminTestSupport::FakeSearchBackend.new([])
    Admin::EventLogSearch.backend = fake

    http.get "/admin/event_logs", { search: { task_id: "abc" } }
    expect(http.last_response.status).to eq(200)
    expect(http.last_response.body.include?("タスクIDは数値")).to eq(true)

    http.get "/admin/event_logs", { search: { layer: "billing" } }
    expect(http.last_response.body.include?("層の指定")).to eq(true)

    http.get "/admin/event_logs", { search: { since: "not-a-time" } }
    expect(http.last_response.body.include?("日時の形式")).to eq(true)

    http.get "/admin/event_logs", { search: { kind: "a b; DROP TABLE x" } }
    expect(http.last_response.body.include?("種別は英数字")).to eq(true)

    http.get "/admin/event_logs", { search: { query: "q" * 501 } }
    expect(http.last_response.body.include?("500文字以内")).to eq(true)

    expect(fake.calls).to eq([])
  end
end

test("limit is clamped and sort params are ignored") do |http:|
  AdminTestSupport.as_admin(http) do
    fake = AdminTestSupport::FakeSearchBackend.new([])
    Admin::EventLogSearch.backend = fake
    http.get "/admin/event_logs", { search: { query: "x", limit: "99999" }, sort: "password", order: "desc" }

    expect(http.last_response.status).to eq(200)
    expect(fake.calls.length).to eq(1)
    expect(fake.calls.first[:limit]).to eq(200)
    expect(fake.calls.first.key?(:sort)).to eq(false)
  end
end

test("search backend failure renders a status, hiding details") do |http:|
  AdminTestSupport.as_admin(http) do
    Admin::EventLogSearch.backend = AdminTestSupport::ExplodingSearchBackend.new
    http.get "/admin/event_logs", { search: { query: "x" } }

    expect(http.last_response.status).to eq(200)
    body = http.last_response.body
    expect(body.include?("検索できませんでした")).to eq(true)
    expect(body.include?("SEKRIT-DETAIL-123")).to eq(false)
  end
end

test("unconfigured search renders an informative status") do |http:|
  AdminTestSupport.as_admin(http) do
    Admin::EventLogSearch.backend = nil
    http.get "/admin/event_logs", { search: { query: "x" } }

    expect(http.last_response.status).to eq(200)
    expect(http.last_response.body.include?("まだ設定されていません")).to eq(true)
  end
end
