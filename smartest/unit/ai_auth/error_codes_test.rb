# frozen_string_literal: true

require "test_helper"
require_relative "../../../app/services/ai_auth/error_codes"

test("sanitize keeps only the explicit allowlist") do
  expect(AiAuth::ErrorCodes.sanitize(nil)).to eq(nil)
  expect(AiAuth::ErrorCodes.sanitize("")).to eq(nil)
  %w[
    invalid_provider invalid_argument spawn_failed timeout unexpected_output
    output_capped challenge_rejected auth_rejected callback_failed
    input_failed cancel_check_failed interrupted unknown
    cancelled expired role_mismatch runtime_unavailable provider_error
  ].each do |code|
    expect(AiAuth::ErrorCodes.sanitize(code)).to eq(code)
  end
end

test("sanitize collapses unsafe and unknown safe-looking text") do
  expect(AiAuth::ErrorCodes.sanitize("raw stderr: token=SECRET detail")).to eq("provider_error")
  expect(AiAuth::ErrorCodes.sanitize("AUTH_EXPIRED")).to eq("provider_error")
  expect(AiAuth::ErrorCodes.sanitize("a" * 65)).to eq("provider_error")
  # Former guessed codes and lowercase sentinels are not persisted.
  expect(AiAuth::ErrorCodes.sanitize("auth_expired")).to eq("provider_error")
  expect(AiAuth::ErrorCodes.sanitize("secret_sentinel_abc")).to eq("provider_error")
  expect(AiAuth::ErrorCodes.sanitize("future_runtime_code")).to eq("provider_error")
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
  expect(AiAuth::ErrorCodes.japanese_code("timeout").include?("タイムアウト")).to eq(true)
  expect(AiAuth::ErrorCodes.japanese_code("auth_rejected").include?("拒否")).to eq(true)
  expect(AiAuth::ErrorCodes.japanese_code("role_mismatch").include?("役割")).to eq(true)
  expect(AiAuth::ErrorCodes.japanese_code("runtime_unavailable").include?("ランタイム")).to eq(true)
  fallback = AiAuth::ErrorCodes.japanese_code("future_runtime_code")
  expect(fallback.include?("エラー")).to eq(true)
  expect(fallback.include?("future_runtime_code")).to eq(false)
  legacy = AiAuth::ErrorCodes.japanese_code("auth_expired")
  expect(legacy.include?("エラー")).to eq(true)
  expect(legacy.include?("auth_expired")).to eq(false)
end
