# frozen_string_literal: true

class CreateOauthAuthAttempts < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_auth_attempts do |t|
      t.string :provider, null: false
      t.string :state_digest, null: false
      t.string :browser_session_digest, null: false, default: ""
      t.string :redirect_uri, null: false, default: ""
      t.text :encrypted_code_verifier
      t.integer :generation_at_start, null: false, default: 0
      t.string :status, null: false, default: "pending"
      t.string :error_code
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :oauth_auth_attempts, :state_digest, unique: true, name: "index_oauth_auth_attempts_on_state_digest"
    add_index :oauth_auth_attempts, :expires_at, name: "index_oauth_auth_attempts_on_expires_at"
    add_index :oauth_auth_attempts, %i[provider status], name: "index_oauth_auth_attempts_on_provider_status"
  end
end
