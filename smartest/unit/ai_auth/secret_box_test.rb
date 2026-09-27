# frozen_string_literal: true

require "test_helper"
require "securerandom"
require_relative "../../../app/services/ai_auth/secret_box"

test("secret box roundtrips hashes and strings as JSON") do
  box = AiAuth::SecretBox.new(key: SecureRandom.bytes(32))

  challenge = { "verification_uri" => "https://example.invalid/auth", "user_code" => "ABCD-1234", "input_required" => true }
  expect(box.decrypt(box.encrypt(challenge))).to eq(challenge)
  expect(box.decrypt(box.encrypt("auth-code-9"))).to eq("auth-code-9")
end

test("ciphertext hides plaintext and uses a random IV") do
  box = AiAuth::SecretBox.new(key: SecureRandom.bytes(32))
  secret = "super-secret-user-code-12345"

  first = box.encrypt(secret)
  second = box.encrypt(secret)

  expect(first.include?(secret)).to eq(false)
  expect(first).not_to eq(second)
  expect(box.decrypt(first)).to eq(secret)
end

test("tampered ciphertext is rejected, never decrypted") do
  box = AiAuth::SecretBox.new(key: SecureRandom.bytes(32))
  ciphertext = box.encrypt({ "verification_uri" => "https://example.invalid/" })
  tampered = ciphertext[0..-3] + (ciphertext[-1] == "A" ? "B" : "A")

  raised = nil
  begin
    box.decrypt(tampered)
  rescue StandardError => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
end

test("keys must be 32 bytes") do
  raised = nil
  begin
    AiAuth::SecretBox.new(key: "short")
  rescue ArgumentError => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
end
