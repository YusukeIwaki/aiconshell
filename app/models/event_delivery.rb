# frozen_string_literal: true

# Outbox spool for not-yet-delivered EventLog rows. This table is a delivery
# spool with per-destination retry state, not a log archive: delivered rows
# are pruned after a short retention, and the searchable history lives in
# ClickHouse (see db/clickhouse/001_create_event_log.sql).
class EventDelivery < ApplicationRecord
  validates :event_id, presence: true, uniqueness: true
  validates :envelope, presence: true
  validates :layer, :kind, :occurred_at, presence: true

  scope :clickhouse_pending, lambda { |now = Time.current|
    where(clickhouse_delivered_at: nil, clickhouse_skipped_at: nil)
      .where("clickhouse_next_retry_at IS NULL OR clickhouse_next_retry_at <= ?", now)
      .order(:id)
  }
  scope :teams_pending, lambda { |now = Time.current|
    where.not(teams_channel: [nil, ""])
      .where(teams_delivered_at: nil, teams_skipped_at: nil)
      .where("teams_next_retry_at IS NULL OR teams_next_retry_at <= ?", now)
      .order(:id)
  }
  scope :prunable, lambda { |before|
    where("created_at < ?", before)
      .where("clickhouse_delivered_at IS NOT NULL OR clickhouse_skipped_at IS NOT NULL")
      .where("teams_channel IS NULL OR teams_channel = '' " \
             "OR teams_delivered_at IS NOT NULL OR teams_skipped_at IS NOT NULL")
  }

  def teams_requested?
    teams_channel.present?
  end

  def clickhouse_terminal?
    clickhouse_delivered_at.present? || clickhouse_skipped_at.present?
  end

  def teams_terminal?
    teams_delivered_at.present? || teams_skipped_at.present?
  end
end
