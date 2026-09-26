# frozen_string_literal: true

require "integration/observability_helper"

# A rescued PostgreSQL write error inside enqueue must roll back only the
# enqueue savepoint: the caller's surrounding business transaction stays
# usable and its work commits.
test("unique conflict inside an outer transaction keeps business work") do |db:, observability_config:|
  adapter = EventLogging::OutboxAdapter.new
  envelope = EventLogTestSupport.build_envelope
  adapter.enqueue(envelope)

  EventDelivery.transaction do
    business = EventDelivery.create!(
      event_id: EventLogTestSupport.build_envelope["event_id"],
      envelope: { "note" => "business" }, layer: "coordination",
      kind: "business.work", occurred_at: Time.current
    )
    # Same event_id: real PG unique violation, contained by the savepoint,
    # returning the existing row instead of raising.
    found = adapter.enqueue(envelope)
    expect(found["event_id"]).to eq(envelope["event_id"])
    expect(EventDelivery.find(business.id).kind).to eq("business.work")
  end

  expect(EventDelivery.where(kind: "business.work").count).to eq(1)
  expect(EventDelivery.where(event_id: envelope["event_id"]).count).to eq(1)
end

test("rescued check violation inside an outer transaction keeps business work") do |db:, observability_config:|
  adapter = EventLogging::OutboxAdapter.new
  # Bypass Envelope.build (which caps kind at 128): direct adapter callers
  # pass model validations but must still hit the DB CHECK.
  bad = EventLogTestSupport.build_envelope
  bad["kind"] = "k" * 200

  EventDelivery.transaction do
    EventDelivery.create!(
      event_id: EventLogTestSupport.build_envelope["event_id"],
      envelope: { "note" => "business" }, layer: "coordination",
      kind: "business.work", occurred_at: Time.current
    )
    begin
      adapter.enqueue(bad)
      raise "expected StatementInvalid"
    rescue ActiveRecord::StatementInvalid => e
      expect(e.message).to match(/event_deliveries_kind_length_check/)
    end
    # The outer transaction is still usable after the rescue.
    expect(EventDelivery.where(kind: "business.work").count).to eq(1)
  end

  expect(EventDelivery.where(kind: "business.work").count).to eq(1)
end

test("best-effort emit failure cannot roll back business work") do |db:, observability_config:|
  log_output = StringIO.new
  Aiconshell::Observability.configure { |config| config.logger = Logger.new(log_output) }

  EventDelivery.transaction do
    EventDelivery.create!(
      event_id: EventLogTestSupport.build_envelope["event_id"],
      envelope: { "note" => "business" }, layer: "coordination",
      kind: "business.work", occurred_at: Time.current
    )
    # Invalid envelope: emit drops with a warning and returns nil.
    expect(EventLogging::Emitter.emit(layer: "bogus", kind: "x", message: "m")).to be_nil
    expect(EventDelivery.where(kind: "business.work").count).to eq(1)
  end

  expect(EventDelivery.where(kind: "business.work").count).to eq(1)
  expect(log_output.string).to match(/emit dropped/)
end
