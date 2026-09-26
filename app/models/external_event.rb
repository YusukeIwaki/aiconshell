# frozen_string_literal: true

# Durable inbox row for one plugin event. Uniqueness includes the fingerprint
# so edits of the same message land as distinct rows.
class ExternalEvent < ApplicationRecord
  belongs_to :task, optional: true
  ACTOR_TYPES = %w[human bot system].freeze

  validates :plugin, :event_id, :fingerprint, :event_type, :resource_id, :occurred_at, presence: true
  validates :actor_type, inclusion: { in: ACTOR_TYPES }
  validates :fingerprint, uniqueness: { scope: %i[plugin event_id] }

  scope :unprocessed, -> { where(processed_at: nil) }
  scope :human, -> { where(actor_type: "human") }

  def processed?
    !processed_at.nil?
  end

  def bot_or_system?
    actor_type != "human"
  end
end
