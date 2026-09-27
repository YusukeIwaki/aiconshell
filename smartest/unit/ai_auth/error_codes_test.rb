# frozen_string_literal: true

require "test_helper"
require_relative "../../../app/services/ai_auth/error_codes"

test("sanitize keeps fixed codes and collapses unsafe text") do
  expect(AiAuth::ErrorCodes.sanitize(nil)).to eq(nil)
  expect(AiAuth::ErrorCodes.sanitize("")).to eq(nil)
  expect(AiAuth::ErrorCodes.sanitize("auth_expired")).to eq("auth_expired")
  expect(AiAuth::ErrorCodes.sanitize("raw stderr: token=SECRET detail")).to eq("provider_error")
  expect(AiAuth::ErrorCodes.sanitize("AUTH_EXPIRED")).to eq("provider_error")
  expect(AiAuth::ErrorCodes.sanitize("a" * 65)).to eq("provider_error")
end

test("sanitize_state only allows runtime terminal states") do
  %w[connected disconnected unavailable failed cancelled expired].each do |state|
    expect(AiAuth::ErrorCodes.sanitize_state(state)).to eq(state)
  end
  expect(AiAuth::ErrorCodes.sanitize_state("root-shell")).to eq(nil)
  expect(AiAuth::ErrorCodes.sanitize_state(nil)).to eq(nil)
end

test("states map to Japanese labels") do
  expect(AiAuth::ErrorCodes.japanese_state("unknown")).to eq("未確認")
  expect(AiAuth::ErrorCodes.japanese_state("connected")).to eq("接続済み")
  expect(AiAuth::ErrorCodes.japanese_state("disconnected")).to eq("未連携")
  expect(AiAuth::ErrorCodes.japanese_state("unavailable")).to eq("準備不足")
  expect(AiAuth::ErrorCodes.japanese_state("failed")).to eq("失敗")
  expect(AiAuth::ErrorCodes.japanese_state("nope")).to eq("不明")
end

test("error codes map to Japanese without leaking raw text") do
  expect(AiAuth::ErrorCodes.japanese_code(nil)).to eq("")
  expect(AiAuth::ErrorCodes.japanese_code("auth_expired").include?("期限")).to eq(true)
  expect(AiAuth::ErrorCodes.japanese_code("role_mismatch").include?("役割")).to eq(true)
  fallback = AiAuth::ErrorCodes.japanese_code("future_runtime_code")
  expect(fallback.include?("エラー")).to eq(true)
  expect(fallback.include?("future_runtime_code")).to eq(false)
end
