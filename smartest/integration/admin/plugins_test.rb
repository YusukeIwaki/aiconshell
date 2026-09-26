# frozen_string_literal: true

require "db_helper"
require_relative "support/admin_test_support"

test("plugins page shows env names only, never values") do |http:|
  AdminTestSupport.as_admin(http) do
    Admin::PluginStatus.registry =
      AdminTestSupport::FakePluginRegistry.new(AdminTestSupport.sample_catalog)
    http.get "/admin/plugins"

    expect(http.last_response.status).to eq(200)
    body = http.last_response.body
    expect(body.include?("github")).to eq(true)
    expect(body.include?("GITHUB_APP_ID")).to eq(true)
    expect(body.include?("GITHUB_PRIVATE_KEY")).to eq(true)
    expect(body.include?("TEAMS_TENANT_ID")).to eq(true)
    expect(body.include?("latest_events")).to eq(true)
    expect(body.include?("非対応")).to eq(true)
    expect(body.include?("未設定")).to eq(true)
    expect(body.include?(AdminTestSupport::PASSWORD)).to eq(false)
  end
end

test("plugins page escapes untrusted catalog text") do |http:|
  evil = [
    {
      "id" => %(<script>alert("plug")</script>),
      "operations" => [{ "name" => "latest_events", "scope" => "r", "unsupported" => false }],
      "required_env" => [],
      "configured" => false
    }
  ]

  AdminTestSupport.as_admin(http) do
    Admin::PluginStatus.registry = AdminTestSupport::FakePluginRegistry.new(evil)
    http.get "/admin/plugins"

    body = http.last_response.body
    expect(body.include?(%(<script>alert("plug")</script>))).to eq(false)
    expect(body.include?("&lt;script&gt;")).to eq(true)
  end
end

test("plugin lane failure renders a notice, not a 500") do |http:|
  AdminTestSupport.as_admin(http) do
    Admin::PluginStatus.registry = AdminTestSupport::ExplodingPluginRegistry.new
    http.get "/admin/plugins"

    expect(http.last_response.status).to eq(200)
    expect(http.last_response.body.include?("取得失敗")).to eq(true)
  end
end

test("missing plugin lane renders an unavailable notice") do |http:|
  AdminTestSupport.as_admin(http) do
    Admin::PluginStatus.registry = nil
    http.get "/admin/plugins"

    expect(http.last_response.status).to eq(200)
    expect(http.last_response.body.include?("診断不可")).to eq(true)
  end
end
