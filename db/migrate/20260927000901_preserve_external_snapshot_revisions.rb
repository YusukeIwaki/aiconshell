# frozen_string_literal: true

class PreserveExternalSnapshotRevisions < ActiveRecord::Migration[8.0]
  def change
    add_column :external_events, :source_fingerprint, :string
    add_column :external_events, :source_updated_at, :datetime

    reversible do |direction|
      direction.up do
        execute <<~SQL
          UPDATE external_events
          SET source_fingerprint = fingerprint, source_updated_at = occurred_at
          WHERE event_type IN ('github.issue', 'jira.issue', 'teams.message', 'teams.reply')
        SQL
      end
    end
  end
end
