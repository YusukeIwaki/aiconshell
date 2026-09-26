# frozen_string_literal: true

require_relative "ai_test_helper"

Ai = Aiconshell::Ai unless defined?(Ai)

test("redactor masks bearer tokens, assignments and known prefixes") do
  expect(Ai::Redactor.redact("auth: Bearer abcDEF123._-")).to eq("auth: bearer [REDACTED]")
  expect(Ai::Redactor.redact("api_key=sk-live-value")).to eq("api_key=[REDACTED]")
  expect(Ai::Redactor.redact("token: sk-abcdefghijklmnop")).to eq("token: [REDACTED]")
  expect(Ai::Redactor.redact("plain prose about tokens stays")).to eq("plain prose about tokens stays")
end

test("redactor excerpts are bounded and single-line") do
  excerpt = Ai::Redactor.excerpt("line one\nline two " + ("x" * 600), max_chars: 20)
  expect(excerpt.length <= 40).to eq(true)
  expect(excerpt.include?("\n")).to eq(false)
  expect(excerpt.end_with?("...(truncated)")).to eq(true)
end

test("failure classification distinguishes auth, limits and missing CLIs") do
  expect(Ai::Redactor.failure_kind("Error: Not logged in")).to eq(:auth)
  expect(Ai::Redactor.failure_kind("usage limit reached")).to eq(:usage_limit)
  expect(Ai::Redactor.failure_kind("HTTP 429 too many requests")).to eq(:usage_limit)
  expect(Ai::Redactor.failure_kind("claude: command not found")).to eq(:not_found)
  expect(Ai::Redactor.failure_kind("something else broke")).to eq(:generic)
end

test("schema validator accepts matching output") do
  data = Ai::SchemaValidator.validate!(AiTestSupport::ANSWER.dup, AiTestSupport::SCHEMA, provider: "codex")
  expect(data).to eq(AiTestSupport::ANSWER)
end

test("schema validator reports pointers without echoing values") do
  begin
    Ai::SchemaValidator.validate!({ "answer" => 42 }, AiTestSupport::SCHEMA, provider: "codex")
    raise "expected InvalidOutput"
  rescue Ai::InvalidOutput => error
    expect(error.message.include?("/answer")).to eq(true)
    expect(error.message.include?("42")).to eq(false)
  end
end

test("schema validator refuses remote refs without network access") do
  schema = { "type" => "object", "$ref" => "https://example.com/schema.json" }
  expect do
    Ai::SchemaValidator.validate!({}, schema, provider: "codex")
  end.to raise_error(ArgumentError)
end

test("schema validator rejects non-hash schemas") do
  expect do
    Ai::SchemaValidator.validate!({}, [], provider: "codex")
  end.to raise_error(ArgumentError)
end
