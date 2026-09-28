# frozen_string_literal: true

# Latest GitHub Apps health check outcome (issue #28). updated_at is the
# last check time; created_at is intentionally absent (see migration).
class GithubAppsHealthCheckState < ApplicationRecord
  STATUSES = %w[unchecked ok error].freeze

  belongs_to :github_apps_account

  validates :status, presence: true, inclusion: { in: STATUSES }

  def ok?
    status == "ok"
  end
end
