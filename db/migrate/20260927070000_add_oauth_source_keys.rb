# frozen_string_literal: true

# Per-connection source isolation for delegated OAuth events/tasks (issue #26).
#
# Provider raw IDs stay unchanged at API boundaries (jira:comment:200,
# issue:PROJ-1, message:team/chan/msg stay exactly as adapters emit them)
# and legacy dedup stays global. OAuth rows isolate by connection scope:
# provider plus fixed tenant/cloud plus the fetching generation
# (connection id, generation, principal). Same numeric IDs on different
# clouds/tenants/generations are distinct sources with distinct watermarks
# and Tasks; reconnecting never rewrites the stored fetch binding.
class AddOauthSourceKeys < ActiveRecord::Migration[8.0]
  OPEN_STATUSES = %w[inbox ready running waiting_human waiting_review waiting_delivery failed].freeze

  def up
    add_column :external_events, :oauth_source_key, :string
    add_column :tasks, :oauth_source_key, :string

    execute(<<~SQL.squish)
      UPDATE external_events SET oauth_source_key =
        COALESCE(oauth_binding ->> 'provider', '') || CHR(31) ||
        COALESCE(oauth_binding ->> 'tenant', '') || CHR(31) ||
        COALESCE(oauth_binding ->> 'cloud', '') || CHR(31) ||
        COALESCE(oauth_binding ->> 'connection_id', '') || CHR(31) ||
        COALESCE(oauth_binding ->> 'generation', '') || CHR(31) ||
        COALESCE(oauth_binding ->> 'principal', '')
      WHERE oauth_binding IS NOT NULL
    SQL
    execute(<<~SQL.squish)
      UPDATE tasks SET oauth_source_key =
        COALESCE(oauth_binding ->> 'provider', '') || CHR(31) ||
        COALESCE(oauth_binding ->> 'tenant', '') || CHR(31) ||
        COALESCE(oauth_binding ->> 'cloud', '') || CHR(31) ||
        COALESCE(oauth_binding ->> 'connection_id', '') || CHR(31) ||
        COALESCE(oauth_binding ->> 'generation', '') || CHR(31) ||
        COALESCE(oauth_binding ->> 'principal', '')
      WHERE oauth_binding IS NOT NULL
    SQL

    remove_index :external_events, name: "index_external_events_on_plugin_event_fingerprint"
    add_index :external_events, %i[plugin event_id fingerprint], unique: true,
      name: "index_external_events_legacy_dedup", where: "oauth_source_key IS NULL"
    add_index :external_events, %i[plugin oauth_source_key event_id fingerprint], unique: true,
      name: "index_external_events_oauth_dedup", where: "oauth_source_key IS NOT NULL"

    remove_index :tasks, name: "index_tasks_one_open_per_source"
    open_list = OPEN_STATUSES.map { |status| "'#{status}'" }.join(", ")
    add_index :tasks, %i[source_plugin source_resource_id], unique: true,
      name: "index_tasks_one_open_per_source_legacy",
      where: "oauth_source_key IS NULL AND source_plugin <> '' AND source_resource_id <> '' " \
             "AND status IN (#{open_list})"
    add_index :tasks, %i[source_plugin oauth_source_key source_resource_id], unique: true,
      name: "index_tasks_one_open_per_source_oauth",
      where: "oauth_source_key IS NOT NULL AND source_plugin <> '' AND source_resource_id <> '' " \
             "AND status IN (#{open_list})"
  end

  def down
    remove_index :external_events, name: "index_external_events_oauth_dedup"
    remove_index :external_events, name: "index_external_events_legacy_dedup"
    add_index :external_events, %i[plugin event_id fingerprint], unique: true,
      name: "index_external_events_on_plugin_event_fingerprint"

    remove_index :tasks, name: "index_tasks_one_open_per_source_oauth"
    remove_index :tasks, name: "index_tasks_one_open_per_source_legacy"
    open_list = OPEN_STATUSES.map { |status| "'#{status}'" }.join(", ")
    add_index :tasks, %i[source_plugin source_resource_id], unique: true,
      name: "index_tasks_one_open_per_source",
      where: "source_plugin <> '' AND source_resource_id <> '' AND status IN (#{open_list})"

    remove_column :external_events, :oauth_source_key
    remove_column :tasks, :oauth_source_key
  end
end
