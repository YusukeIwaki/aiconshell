# frozen_string_literal: true

require "db_helper"
require_relative "support/admin_test_support"

test("policy index lists all three layers with worker snapshots") do |http:|
  LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
  AiConnection.create!(provider: "codex", worker_role: "control",
                       state: "connected", checked_at: Time.current)

  AdminTestSupport.as_admin(http) do
    http.get "/admin/layer_policies"

    expect(http.last_response.status).to eq(200)
    body = http.last_response.body
    expect(body.include?("対話層")).to eq(true)
    expect(body.include?("整理層")).to eq(true)
    expect(body.include?("実行層")).to eq(true)
    expect(body.include?("codex")).to eq(true)
    expect(body.include?("接続済み")).to eq(true)
    expect(body.include?("control worker")).to eq(true)
  end
end

test("policy form always offers claude/codex/muse") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/layer_policies/coordination/edit"

    body = http.last_response.body
    %w[claude codex muse].each do |provider|
      expect(body.include?(provider)).to eq(true)
    end
  end
end

test("unconfigured provider can be selected and saved") do |http:|
  AiConnection.create!(provider: "muse", worker_role: "execution",
                       state: "disconnected", checked_at: Time.current)

  AdminTestSupport.as_admin(http) do
    http.patch "/admin/layer_policies/execution",
      { layer_policy: { provider: "muse", model: "muse-spark-1.3-contributor",
                        effort: "max", instructions: "丁寧に", enabled: "1" } }

    expect(http.last_response.status).to eq(302)
    policy = LayerPolicy.find_by(layer: "execution")
    expect(policy.provider).to eq("muse")
    expect(policy.instructions).to eq("丁寧に")
  end
end

test("unknown provider is rejected, not saved") do |http:|
  AdminTestSupport.as_admin(http) do
    http.patch "/admin/layer_policies/coordination",
      { layer_policy: { provider: "gpt", model: "x" } }

    expect(http.last_response.status).to eq(422)
    expect(http.last_response.body.include?("claude / codex / muse")).to eq(true)
    expect(LayerPolicy.find_by(layer: "coordination")).to eq(nil)
  end
end

test("blank provider is rejected") do |http:|
  AdminTestSupport.as_admin(http) do
    http.patch "/admin/layer_policies/coordination",
      { layer_policy: { provider: "", model: "x" } }

    expect(http.last_response.status).to eq(422)
    expect(LayerPolicy.find_by(layer: "coordination")).to eq(nil)
  end
end

test("unknown layer redirects to index") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/layer_policies/billing/edit"
    expect(http.last_response.status).to eq(302)

    http.patch "/admin/layer_policies/billing", { layer_policy: { provider: "codex" } }
    expect(http.last_response.status).to eq(302)
    expect(LayerPolicy.find_by(layer: "billing")).to eq(nil)
  end
end

test("policy page renders unknown when no snapshot exists") do |http:|
  LayerPolicy.create!(layer: "interaction", provider: "claude", enabled: true)

  AdminTestSupport.as_admin(http) do
    http.get "/admin/layer_policies"

    expect(http.last_response.status).to eq(200)
    body = http.last_response.body
    expect(body.include?("claude")).to eq(true)
    expect(body.include?("未確認")).to eq(true)
    expect(body.include?("保存可")).to eq(true)
  end
end

test("execution layer reads the execution snapshot, not control") do |http:|
  LayerPolicy.create!(layer: "execution", provider: "muse", enabled: true)
  AiConnection.create!(provider: "muse", worker_role: "control",
                       state: "connected", checked_at: Time.current)
  AiConnection.create!(provider: "muse", worker_role: "execution",
                       state: "disconnected", checked_at: Time.current)

  AdminTestSupport.as_admin(http) do
    http.get "/admin/layer_policies"

    body = http.last_response.body
    expect(body.include?("未連携")).to eq(true)
    expect(body.include?("execution worker")).to eq(true)
  end
end

test("failed snapshot shows safe Japanese error with role and time") do |http:|
  LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
  checked = Time.current
  AiConnection.create!(provider: "codex", worker_role: "control",
                       state: "failed", error_code: "spawn_failed",
                       checked_at: checked)

  AdminTestSupport.as_admin(http) do
    http.get "/admin/layer_policies/coordination/edit"

    body = http.last_response.body
    expect(body.include?("失敗")).to eq(true)
    expect(body.include?("起動に失敗")).to eq(true)
    expect(body.include?("control worker")).to eq(true)
    expect(body.include?("spawn_failed")).to eq(false)
  end
end
