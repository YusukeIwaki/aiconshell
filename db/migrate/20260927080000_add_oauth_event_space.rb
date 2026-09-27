# frozen_string_literal: true

# Generation-independent OAuth event identity for issue #26.
#
# Re-fetching an already-handled external revision after a reconnect must
# not create new work: external event dedup scopes by provider resource
# space (provider plus fixed tenant/cloud) with the raw provider IDs
# unchanged, never by fetching generation. A different cloud/tenant with
# the same numeric IDs stays a distinct space. Task joins and reply
# permission stay generation-pinned via `oauth_source_key` (see
# 20260927070000_add_oauth_source_keys.rb), which this migration leaves
# untouched on both tables.
class AddOauthEventSpace < ActiveRecord::Migration[8.0]
  def up
    add_column :external_events, :oauth_event_space, :string

    execute(<<~SQL.squish)
      UPDATE external_events SET oauth_event_space =
        COALESCE(oauth_binding ->> 'provider', '') || CHR(31) ||
        COALESCE(oauth_binding ->> 'tenant', '') || CHR(31) ||
        COALESCE(oauth_binding ->> 'cloud', '')
      WHERE oauth_binding IS NOT NULL
    SQL

    remove_index :external_events, name: "index_external_events_oauth_dedup"
    add_index :external_events, %i[plugin oauth_event_space event_id fingerprint], unique: true,
      name: "index_external_events_oauth_dedup", where: "oauth_event_space IS NOT NULL"
  end

  def down
    remove_index :external_events, name: "index_external_events_oauth_dedup"
    add_index :external_events, %i[plugin oauth_source_key event_id fingerprint], unique: true,
      name: "index_external_events_oauth_dedup", where: "oauth_source_key IS NOT NULL"

    remove_column :external_events, :oauth_event_space
  end
end
