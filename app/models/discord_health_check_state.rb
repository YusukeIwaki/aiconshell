# frozen_string_literal: true

# Latest Discord health check outcome (issue #28). updated_at is the last
# check time; created_at is intentionally absent (see migration).
class DiscordHealthCheckState < ApplicationRecord
  STATUSES = %w[unchecked ok error].freeze

  belongs_to :discord_account

  validates :status, presence: true, inclusion: { in: STATUSES }

  def ok?
    status == "ok"
  end
end
