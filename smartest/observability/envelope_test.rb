# frozen_string_literal: true

require "event_log_helper"

Envelope = Aiconshell::Observability::Envelope
ValidationError = Aiconshell::Observability::ValidationError

test("builds a defaulted envelope") do |fixed_clock:|
  envelope = Envelope.build(
    layer: "coordination", kind: "task.prioritized",
    message: "Priority updated", task_id: 3,
    correlation_id: "corr-1", data: { "priority" => 10 }, clock: fixed_clock
  )

  expect(envelope["event_id"]).to match(/\A[0-9a-f-]{36}\z/)
  expect(envelope["occurred_at"]).to eq("2026-09-26T12:00:00.000Z")
  expect(envelope["version"]).to eq(1)
  expect(envelope["data"]).to eq({ "priority" => 10 })
end

test("redacts before validating so stored bytes are safe") do
  envelope = Envelope.build(
    layer: "execution", kind: "run.finished", message: "mail bob@example.com",
    data: { "token" => "secret", "nested" => [{ "password" => "p" }] }
  )

  expect(envelope["message"]).to eq("mail [redacted-email]")
  expect(envelope["data"]["token"]).to eq("[REDACTED]")
  expect(envelope["data"]["nested"]).to eq([{ "password" => "[REDACTED]" }])
end

test("rejects unknown layers, bad kinds, and bad timestamps") do
  expect(-> { Envelope.build(layer: "nope", kind: "a.b", message: "m") })
    .to raise_error(ValidationError)
  expect(-> { Envelope.build(layer: "coordination", kind: "Bad Kind!", message: "m") })
    .to raise_error(ValidationError)
  expect(-> {
    Envelope.build(layer: "coordination", kind: "a.b", message: "m", occurred_at: "not-a-time")
  }).to raise_error(ValidationError)
end

test("rejects non-hash data and non-serializable values") do
  expect(-> { Envelope.build(layer: "coordination", kind: "a.b", message: "m", data: [1]) })
    .to raise_error(ValidationError)
  expect(-> {
    Envelope.build(layer: "coordination", kind: "a.b", message: "m", data: { "x" => Object.new })
  }).to raise_error(ValidationError)
end

test("truncates long messages but rejects oversized data") do
  envelope = Envelope.build(layer: "coordination", kind: "a.b", message: "y" * 5000)

  expect(envelope["message"].length).to eq(4000)

  big = (1..30).to_h { |i| ["key#{i}", "z" * 2000] }
  expect(-> { Envelope.build(layer: "coordination", kind: "a.b", message: "m", data: big) })
    .to raise_error(ValidationError)
end

test("validate! accepts built envelopes and rejects unknown keys") do
  envelope = Envelope.build(layer: "interaction", kind: "message.received", message: "hi")

  expect(Envelope.validate!(envelope)).to eq(envelope)
  expect(-> { Envelope.validate!(envelope.merge("extra" => 1)) }).to raise_error(ValidationError)
end
