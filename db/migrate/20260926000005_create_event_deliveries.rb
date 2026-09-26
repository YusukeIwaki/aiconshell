# frozen_string_literal: true

class CreateEventDeliveries < ActiveRecord::Migration[8.0]
  def change
    create_table :event_deliveries do |t|
      t.text :event_id, null: false
      t.jsonb :envelope, null: false, default: {}
      t.text :layer, null: false
      t.text :kind, null: false
      t.bigint :task_id
      t.text :correlation_id
      t.timestamptz :occurred_at, null: false
      t.text :teams_channel

      t.timestamptz :clickhouse_delivered_at
      t.integer :clickhouse_attempts, null: false, default: 0
      t.timestamptz :clickhouse_next_retry_at
      t.text :clickhouse_last_error
      t.timestamptz :clickhouse_skipped_at

      t.timestamptz :teams_delivered_at
      t.integer :teams_attempts, null: false, default: 0
      t.timestamptz :teams_next_retry_at
      t.text :teams_last_error
      t.timestamptz :teams_skipped_at

      t.timestamps
    end

    add_index :event_deliveries, :event_id, unique: true
    add_index :event_deliveries, %i[clickhouse_delivered_at clickhouse_next_retry_at],
              name: "index_event_deliveries_on_clickhouse_pending"
    add_index :event_deliveries, %i[teams_delivered_at teams_next_retry_at],
              name: "index_event_deliveries_on_teams_pending"
    add_index :event_deliveries, :occurred_at
  end
end
