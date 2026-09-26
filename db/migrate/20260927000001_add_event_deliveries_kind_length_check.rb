# frozen_string_literal: true

# Defense-in-depth for the EventLog outbox: the envelope contract already caps
# kind at 128 chars, but a direct OutboxAdapter#enqueue caller bypasses it.
# The CHECK keeps oversized rows out at the database level (raising
# ActiveRecord::StatementInvalid, contained by the enqueue savepoint).
class AddEventDeliveriesKindLengthCheck < ActiveRecord::Migration[8.0]
  def change
    add_check_constraint :event_deliveries, "char_length(kind) <= 128",
                         name: "event_deliveries_kind_length_check"
  end
end
