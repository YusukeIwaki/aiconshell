# frozen_string_literal: true

class CreateAiConnections < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_connections do |t|
      t.string :provider, null: false
      t.string :worker_role, null: false
      t.string :state, null: false, default: "unknown"
      t.string :error_code
      t.datetime :checked_at
      t.string :last_session_uuid
      t.bigint :last_session_id

      t.timestamps
    end

    add_index :ai_connections, %i[provider worker_role], unique: true, name: "index_ai_connections_on_provider_and_role"
    add_index :ai_connections, :state, name: "index_ai_connections_on_state"
  end
end
