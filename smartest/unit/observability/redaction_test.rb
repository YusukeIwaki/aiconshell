# frozen_string_literal: true

require "test_helper"
require "event_log_fixtures"

Redaction = Aiconshell::Observability::Redaction

test("redacts sensitive keys case-insensitively") do
  input = {
    "token" => "abc", "Authorization" => "Bearer xyz",
    "api_key" => "k", "client_secret" => "s",
    "nested" => { "PASSWORD" => "p", :session_id => "sess" }
  }
  redacted = Redaction.redact(input)

  expect(redacted["token"]).to eq("[REDACTED]")
  expect(redacted["Authorization"]).to eq("[REDACTED]")
  expect(redacted["api_key"]).to eq("[REDACTED]")
  expect(redacted["client_secret"]).to eq("[REDACTED]")
  expect(redacted["nested"]["PASSWORD"]).to eq("[REDACTED]")
  expect(redacted["nested"][:session_id]).to eq("[REDACTED]")
end

test("preserves innocent keys that merely contain generic words") do
  redacted = Redaction.redact({ "author" => "ana", "idempotency_key" => "k-1", "kind" => "x" })

  expect(redacted).to eq({ "author" => "ana", "idempotency_key" => "k-1", "kind" => "x" })
end

test("drops AI prompt and raw CLI output carriers") do
  redacted = Redaction.redact({ "prompt" => "do evil", "stdout" => "logs", "result" => "ok" })

  expect(redacted["prompt"]).to eq("[REDACTED]")
  expect(redacted["stdout"]).to eq("[REDACTED]")
  expect(redacted["result"]).to eq("ok")
end

test("redacts emails, bearer tokens, and credential params inside strings") do
  redacted = Redaction.redact_string("contact ana@example.com with Bearer abc.def-ghi token=zzz")

  expect(redacted).not_to match(/ana@example\.com/)
  expect(redacted).not_to match(/Bearer abc/)
  expect(redacted).not_to match(/token=zzz/)
  expect(redacted).to match(/\[redacted-email\]/)
end

test("redacts values inside arrays without mutating the input") do
  input = [{ "secret" => "s" }, "plain", ["Bearer tok123"]]
  redacted = Redaction.redact(input)

  expect(redacted[0]).to eq({ "secret" => "[REDACTED]" })
  expect(redacted[1]).to eq("plain")
  expect(redacted[2]).to eq(["[REDACTED]"])
  expect(input[0]).to eq({ "secret" => "s" })
end

test("sanitize_error never copies arbitrary exception messages") do
  error = RuntimeError.new("unlabelled-sensitive-sentinel token=supersecret user bob@example.com\n" + ("x" * 600))

  message = Redaction.sanitize_error(error)

  expect(message).to eq("RuntimeError")
  expect(message).not_to match(/unlabelled-sensitive-sentinel/)
  expect(message).not_to match(/\n/)
  expect(message).not_to match(/supersecret/)
  expect(message).not_to match(/bob@example\.com/)
  expect(message.length <= 500 + RuntimeError.name.length + 2).to eq(true)
end

test("truncate_string keeps short strings and marks cuts") do
  expect(Redaction.truncate_string("abc", 10)).to eq("abc")

  cut = Redaction.truncate_string("x" * 30, 20)
  expect(cut.length).to eq(20)
  expect(cut).to match(/…\(truncated\)\z/)
end
