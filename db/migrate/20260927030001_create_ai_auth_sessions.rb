# frozen_string_literal: true

class CreateAiAuthSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_auth_sessions do |t|
      t.string :uuid, null: false
      t.string :provider, null: false
      t.string :worker_role, null: false
      t.string :operation, null: false
      t.string :status, null: false, default: "queued"
      t.datetime :expires_at, null: false
      t.string :claim_token
      t.datetime :claimed_at
      t.datetime :heartbeat_at
      t.boolean :cancel_requested, null: false, default: false
      t.text :encrypted_challenge
      t.datetime :challenge_updated_at
      t.text :encrypted_input_code
      t.datetime :input_updated_at
      t.string :result_state
      t.string :result_error_code
      t.datetime :finished_at

      t.timestamps
    end

    add_index :ai_auth_sessions, :uuid, unique: true, name: "index_ai_auth_sessions_on_uuid"
    add_index :ai_auth_sessions, :claim_token, unique: true, name: "index_ai_auth_sessions_on_claim_token"
    add_index :ai_auth_sessions, %i[provider worker_role status],
              name: "index_ai_auth_sessions_on_provider_role_status"
    add_index :ai_auth_sessions, :expires_at, name: "index_ai_auth_sessions_on_expires_at"
    add_index :ai_auth_sessions, %i[provider worker_role], unique: true,
              where: "status IN ('queued', 'running', 'waiting')",
              name: "index_ai_auth_sessions_one_active_per_provider_role"
  end
end
