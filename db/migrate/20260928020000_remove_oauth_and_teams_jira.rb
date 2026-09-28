# frozen_string_literal: true

# Issue #28: remove the delegated-OAuth lane (user consent for Jira/Teams),
# the Teams/Jira operational rows, and the EventLog Teams delivery columns.
# Supported integrations are GitHub Apps and Discord only; Teams/Jira will
# be re-added later under the account model.
#
# Data handling for removed plugins (jira, teams, jira_oauth, teams_oauth):
# inbox/cursor/outbound rows can never be actioned again (their adapters
# are gone), so they are deleted. Tasks are user-visible history: open
# ones are cancelled with an explanation instead of deleted, keeping
# feedback, runs, and admin receipts intact.
class RemoveOauthAndTeamsJira < ActiveRecord::Migration[8.0]
  REMOVED_PLUGINS = %w[jira teams jira_oauth teams_oauth].freeze
  OPEN_STATUSES = %w[inbox ready running waiting_human waiting_review waiting_delivery failed].freeze

  def up
    plugin_list = REMOVED_PLUGINS.map { |name| "'#{name}'" }.join(", ")
    open_list = OPEN_STATUSES.map { |status| "'#{status}'" }.join(", ")
    execute("DELETE FROM external_events WHERE plugin IN (#{plugin_list})")
    execute("DELETE FROM integration_cursors WHERE plugin IN (#{plugin_list})")
    execute("DELETE FROM outbound_actions WHERE plugin IN (#{plugin_list})")
    execute(<<~SQL.squish)
      UPDATE tasks SET status = 'cancelled',
        last_error = 'Integration removed (issue #28): Teams/Jira support will be re-added later',
        updated_at = NOW()
      WHERE source_plugin IN (#{plugin_list}) AND status IN (#{open_list})
    SQL

    drop_table :oauth_auth_attempts
    drop_table :oauth_connections

    remove_column :integration_cursors, :oauth_binding
    remove_column :outbound_actions, :oauth_binding
    remove_column :external_events, :oauth_binding
    remove_column :tasks, :oauth_binding

    remove_index :external_events, name: "index_external_events_oauth_dedup"
    remove_index :external_events, name: "index_external_events_legacy_dedup"
    remove_column :external_events, :oauth_source_key
    remove_column :external_events, :oauth_event_space
    add_index :external_events, %i[plugin event_id fingerprint], unique: true,
      name: "index_external_events_on_plugin_event_fingerprint"

    remove_index :tasks, name: "index_tasks_one_open_per_source_oauth"
    remove_index :tasks, name: "index_tasks_one_open_per_source_legacy"
    remove_column :tasks, :oauth_source_key
    add_index :tasks, %i[source_plugin source_resource_id], unique: true,
      name: "index_tasks_one_open_per_source",
      where: "source_plugin <> '' AND source_resource_id <> '' AND status IN (#{open_list})"

    remove_index :event_deliveries, name: "index_event_deliveries_on_teams_pending"
    remove_column :event_deliveries, :teams_channel
    remove_column :event_deliveries, :teams_delivered_at
    remove_column :event_deliveries, :teams_attempts
    remove_column :event_deliveries, :teams_next_retry_at
    remove_column :event_deliveries, :teams_last_error
    remove_column :event_deliveries, :teams_skipped_at
  end

  def down
    add_column :event_deliveries, :teams_channel, :text
    add_column :event_deliveries, :teams_delivered_at, :timestamptz
    add_column :event_deliveries, :teams_attempts, :integer, default: 0, null: false
    add_column :event_deliveries, :teams_next_retry_at, :timestamptz
    add_column :event_deliveries, :teams_last_error, :text
    add_column :event_deliveries, :teams_skipped_at, :timestamptz
    add_index :event_deliveries, %i[teams_delivered_at teams_next_retry_at],
      name: "index_event_deliveries_on_teams_pending"

    open_list = OPEN_STATUSES.map { |status| "'#{status}'" }.join(", ")
    remove_index :tasks, name: "index_tasks_one_open_per_source"
    add_column :tasks, :oauth_source_key, :string
    add_column :tasks, :oauth_binding, :jsonb
    add_index :tasks, %i[source_plugin source_resource_id], unique: true,
      name: "index_tasks_one_open_per_source_legacy",
      where: "oauth_source_key IS NULL AND source_plugin <> '' AND source_resource_id <> '' " \
             "AND status IN (#{open_list})"
    add_index :tasks, %i[source_plugin oauth_source_key source_resource_id], unique: true,
      name: "index_tasks_one_open_per_source_oauth",
      where: "oauth_source_key IS NOT NULL AND source_plugin <> '' AND source_resource_id <> '' " \
             "AND status IN (#{open_list})"

    remove_index :external_events, name: "index_external_events_on_plugin_event_fingerprint"
    add_column :external_events, :oauth_source_key, :string
    add_column :external_events, :oauth_event_space, :string
    add_column :external_events, :oauth_binding, :jsonb
    add_index :external_events, %i[plugin event_id fingerprint], unique: true,
      name: "index_external_events_legacy_dedup", where: "oauth_source_key IS NULL"
    add_index :external_events, %i[plugin oauth_event_space event_id fingerprint], unique: true,
      name: "index_external_events_oauth_dedup", where: "oauth_event_space IS NOT NULL"

    add_column :outbound_actions, :oauth_binding, :jsonb
    add_column :integration_cursors, :oauth_binding, :jsonb

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
      t.string :client_id
      t.timestamps
    end
    add_index :oauth_connections, :provider, unique: true, name: "index_oauth_connections_on_provider"
    add_index :oauth_connections, :refresh_lease_token, unique: true, name: "index_oauth_connections_on_refresh_lease"
    add_index :oauth_connections, :state, name: "index_oauth_connections_on_state"

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
      t.string :client_id
      t.string :cloud_id
      t.string :tenant_id
      t.text :scopes, null: false, default: ""
      t.timestamps
    end
    add_index :oauth_auth_attempts, :state_digest, unique: true, name: "index_oauth_auth_attempts_on_state_digest"
    add_index :oauth_auth_attempts, :expires_at, name: "index_oauth_auth_attempts_on_expires_at"
    add_index :oauth_auth_attempts, %i[provider status], name: "index_oauth_auth_attempts_on_provider_status"
  end
end
