# frozen_string_literal: true

# Issue #28: integration accounts live in the database instead of the
# environment. One singleton row per provider (GitHub Apps / Discord),
# each with a has_one health check state whose updated_at is the last
# check time (no created_at by design). The JSON admin API token moves
# here as well (digest only; plaintext is shown once at rotation).
class CreateIntegrationAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :github_apps_accounts do |t|
      t.string :app_id, default: "", null: false
      t.string :installation_id, default: "", null: false
      t.text :encrypted_private_key
      t.string :private_key_fingerprint
      t.string :api_url, default: "", null: false
      t.timestamps
    end

    create_table :github_apps_health_check_states do |t|
      t.references :github_apps_account, null: false, foreign_key: true, index: { unique: true }
      t.string :status, default: "unchecked", null: false
      t.string :error_code
      # updated_at doubles as the last health check time; created_at is
      # intentionally absent.
      t.datetime :updated_at, null: false
    end

    create_table :discord_accounts do |t|
      t.text :encrypted_bot_token
      t.timestamps
    end

    create_table :discord_health_check_states do |t|
      t.references :discord_account, null: false, foreign_key: true, index: { unique: true }
      t.string :status, default: "unchecked", null: false
      t.string :error_code
      # updated_at doubles as the last health check time; created_at is
      # intentionally absent.
      t.datetime :updated_at, null: false
    end

    create_table :admin_api_tokens do |t|
      t.string :token_digest, null: false
      t.string :prefix, default: "", null: false
      t.timestamps
      t.index :token_digest, unique: true
    end
  end
end
