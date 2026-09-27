# frozen_string_literal: true

class AddOauthConfigSnapshots < ActiveRecord::Migration[8.0]
  def change
    add_column :oauth_auth_attempts, :client_id, :string
    add_column :oauth_auth_attempts, :cloud_id, :string
    add_column :oauth_auth_attempts, :tenant_id, :string
    add_column :oauth_auth_attempts, :scopes, :text, default: "", null: false
    add_column :oauth_connections, :client_id, :string
  end
end
