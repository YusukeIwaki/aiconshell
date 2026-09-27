# frozen_string_literal: true

require "test_helper"
require "securerandom"
require_relative "../../../lib/aiconshell/oauth"

test("secret box roundtrips hashes and strings") do
  box = Aiconshell::Oauth::SecretBox.new(key: SecureRandom.bytes(32))

  tokens = { "access_token" => "at-secret", "refresh_token" => "rt-secret" }
  expect(box.decrypt(box.encrypt(tokens))).to eq(tokens)
  expect(box.decrypt(box.encrypt("verifier-secret"))).to eq("verifier-secret")
end

test("ciphertext hides plaintext and uses a random IV") do
  box = Aiconshell::Oauth::SecretBox.new(key: SecureRandom.bytes(32))
  secret = "super-secret-access-token-12345"

  first = box.encrypt(secret)
  second = box.encrypt(secret)

  expect(first.include?(secret)).to eq(false)
  expect(first).not_to eq(second)
  expect(box.decrypt(first)).to eq(secret)
end

test("tampered ciphertext is rejected, never decrypted") do
  box = Aiconshell::Oauth::SecretBox.new(key: SecureRandom.bytes(32))
  ciphertext = box.encrypt({ "access_token" => "at-1" })
  tampered = ciphertext[0..-3] + (ciphertext[-1] == "A" ? "B" : "A")

  raised = nil
  begin
    box.decrypt(tampered)
  rescue StandardError => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
end

test("a different key cannot read the ciphertext") do
  first = Aiconshell::Oauth::SecretBox.new(key: SecureRandom.bytes(32))
  second = Aiconshell::Oauth::SecretBox.new(key: SecureRandom.bytes(32))

  raised = nil
  begin
    second.decrypt(first.encrypt("token-secret"))
  rescue StandardError => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
end

test("keys must be 32 bytes") do
  raised = nil
  begin
    Aiconshell::Oauth::SecretBox.new(key: "short")
  rescue ArgumentError => e
    raised = e
  end
  expect(raised.nil?).to eq(false)
end

test("derivation uses the dedicated oauth salt") do
  expect(Aiconshell::Oauth::SecretBox::SALT).to eq("aiconshell oauth v1")

  key = Aiconshell::Oauth::SecretBox.derive_key("base-secret")
  expect(key.bytesize).to eq(32)
  expect(Aiconshell::Oauth::SecretBox.derive_key("base-secret")).to eq(key)
  expect(Aiconshell::Oauth::SecretBox.derive_key("other-secret") == key).to eq(false)
end

test("state digests are opaque and session-bound") do
  first = Aiconshell::Oauth::State.generate
  second = Aiconshell::Oauth::State.generate

  expect(first[:raw] == second[:raw]).to eq(false)
  expect(first[:digest].include?(first[:raw])).to eq(false)
  expect(Aiconshell::Oauth::State.matches?(first[:digest], first[:raw])).to eq(true)
  expect(Aiconshell::Oauth::State.matches?(first[:digest], second[:raw])).to eq(false)
  expect(Aiconshell::Oauth::State.matches?(first[:digest], "")).to eq(false)
  expect(Aiconshell::Oauth::State.matches?(first[:digest], nil)).to eq(false)

  expect(Aiconshell::Oauth::State.digest_session("sess-1")).to eq(
    Aiconshell::Oauth::State.digest_session("sess-1")
  )
  expect(Aiconshell::Oauth::State.digest_session("sess-1") == Aiconshell::Oauth::State.digest_session("sess-2")).to eq(false)
  expect(Aiconshell::Oauth::State.digest_session("sess-1").include?("sess-1")).to eq(false)
end

test("pkce S256 matches an independent openssl digest") do
  # RFC 7636 Appendix B verifier; the challenge below was cross-checked
  # with `openssl dgst -sha256 -binary | openssl base64 -A` (43 chars,
  # urlsafe, no padding), not copied from memory.
  verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  expect(Aiconshell::Oauth::Pkce.challenge(verifier)).to eq("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

  generated = Aiconshell::Oauth::Pkce.generate
  expect(Aiconshell::Oauth::Pkce.valid_verifier?(generated[:verifier])).to eq(true)
  expect(generated[:challenge]).to eq(Aiconshell::Oauth::Pkce.challenge(generated[:verifier]))
  expect(Aiconshell::Oauth::Pkce.valid_verifier?("short")).to eq(false)
  expect(Aiconshell::Oauth::Pkce.valid_verifier?(nil)).to eq(false)
end

test("error codes collapse unknown values to provider_error") do
  codes = Aiconshell::Oauth::ErrorCodes

  expect(codes.sanitize("invalid_grant")).to eq("invalid_grant")
  expect(codes.sanitize("evil_code")).to eq("provider_error")
  expect(codes.sanitize("Error with spaces")).to eq("provider_error")
  expect(codes.sanitize(nil)).to eq(nil)
  expect(codes.sanitize("")).to eq(nil)
  expect(codes.needs_reauth?("invalid_grant")).to eq(true)
  expect(codes.needs_reauth?("timeout")).to eq(false)
  expect(codes.transient?("rate_limited")).to eq(true)
  expect(codes.transient?("invalid_grant")).to eq(false)
end
