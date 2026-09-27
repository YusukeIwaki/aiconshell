# frozen_string_literal: true

# Durable inbox row for one plugin event. Uniqueness includes the fingerprint
# so edits of the same message land as distinct rows. Delegated OAuth rows
# dedup by provider resource space (`oauth_event_space`: provider plus
# fixed tenant/cloud, never the fetching generation), so re-fetching an
# already-handled revision after a reconnect creates no new row; legacy
# rows keep global plugin/event/fingerprint dedup with a NULL space. Each
# OAuth row also keeps its immutable fetch binding plus the
# generation-scoped Task join key (`oauth_source_key`), which triage uses
# to pin new work to the fetching generation without joining old Tasks.
class ExternalEvent < ApplicationRecord
  belongs_to :task, optional: true
  ACTOR_TYPES = %w[human bot system].freeze

  validates :plugin, :event_id, :fingerprint, :event_type, :resource_id, :occurred_at, presence: true
  validates :actor_type, inclusion: { in: ACTOR_TYPES }
  validates :fingerprint, uniqueness: { scope: %i[plugin event_id oauth_event_space] }

  scope :unprocessed, -> { where(processed_at: nil) }
  scope :human, -> { where(actor_type: "human") }

  def processed?
    !processed_at.nil?
  end

  def bot_or_system?
    actor_type != "human"
  end
end
