# frozen_string_literal: true

# Per-layer AI selection. All layers are optional/unconfigured at boot:
# saving a policy that names an unconfigured provider is valid; the failure
# surfaces as a structured runtime error, never as a validation error.
# No secrets are stored here.
class LayerPolicy < ApplicationRecord
  LAYERS = %w[interaction coordination execution].freeze
  PROVIDERS = %w[claude codex muse].freeze

  validates :layer, presence: true, inclusion: { in: LAYERS }, uniqueness: true
  validates :provider, presence: true, inclusion: { in: PROVIDERS }

  scope :enabled, -> { where(enabled: true) }

  def self.for_layer(layer)
    find_by(layer: layer.to_s)
  end

  def self.enabled_for(layer)
    find_by(layer: layer.to_s, enabled: true)
  end
end
