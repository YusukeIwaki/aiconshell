# frozen_string_literal: true

# Per-plugin/scope poll cursor. The cursor advances only after every event of
# the poll is durably persisted. Short leases guard against overlapping polls.
class IntegrationCursor < ApplicationRecord
  validates :plugin, :scope, presence: true
  validates :scope, uniqueness: { scope: :plugin }

  def lease_active?(now = Time.current)
    lease_token.present? && lease_expires_at.present? && lease_expires_at > now
  end
end
