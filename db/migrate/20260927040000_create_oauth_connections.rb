# frozen_string_literal: true

class CreateOauthConnections < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_connections do |t|
      t.string :provider, null: false
      t.integer :generation, null: false, default: 0
      t.string :state, null: false, default: "unknown"
      t.string :error_code
      t.string :external_principal, null: false, default: ""
      t.string :display_name, null: false, default: ""
      t.string :tenant_id
      t.string :cloud_id
      t.text :granted_scopes, null: false, default: ""
      t.text :encrypted_access_token
      t.text :encrypted_refresh_token
      t.datetime :token_expires_at
      t.string :refresh_lease_token
      t.datetime :refresh_lease_expires_at
      t.integer :refresh_lease_generation

      t.timestamps
    end

    add_index :oauth_connections, :provider, unique: true, name: "index_oauth_connections_on_provider"
    add_index :oauth_connections, :refresh_lease_token, unique: true, name: "index_oauth_connections_on_refresh_lease"
    add_index :oauth_connections, :state, name: "index_oauth_connections_on_state"
  end
end
