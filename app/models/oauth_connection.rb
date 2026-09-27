# frozen_string_literal: true

# Explicit full root (no defined? guard): a pre-defined ErrorCodes never
# implies the whole entry (State, Pkce, TokenSet, Binding, PROVIDERS) is
# loaded.
require "aiconshell/oauth"

# One user-delegated OAuth connection per provider (atlassian / microsoft).
# Tokens live here only as authenticated ciphertext; plaintext is decrypted
# in memory for a single exchange/refresh and never logged, inspected, or
# serialized. A successful replacement and every local disconnect bump
# +generation; a plain token refresh keeps it. Later plugins receive only
# the secret-free binding (see Aiconshell::Oauth::Binding).
class OauthConnection < ApplicationRecord
  PROVIDERS = %w[atlassian microsoft].freeze
  STATES = %w[unknown connected needs_reauth disconnected failed].freeze

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :state, presence: true, inclusion: { in: STATES }
  validates :provider, uniqueness: true
  validates :generation, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def connected?
    state == "connected"
  end

  # Snapshot for binding comparison. No secrets, no ciphertext.
  def binding_snapshot
    {
      "connection_id" => id,
      "generation" => generation,
      "provider" => provider,
      "principal" => external_principal.to_s,
      "tenant" => tenant_id,
      "cloud" => cloud_id
    }
  end

  # Safe public status for diagnostics and the future admin UI. Never
  # includes tokens, verifiers, ciphertext, or raw errors.
  def public_status
    {
      "provider" => provider,
      "state" => state,
      "connected" => connected?,
      "principal" => external_principal.to_s,
      "display_name" => display_name.to_s,
      "tenant" => tenant_id,
      "cloud" => cloud_id,
      "scopes" => scopes_list,
      "token_expires_at" => token_expires_at&.iso8601,
      "error_code" => error_code,
      "generation" => generation
    }
  end

  def scopes_list
    granted_scopes.to_s.split(/[,\s]+/).reject(&:empty?)
  end

  def refresh_lease_held?(now = Time.current)
    refresh_lease_token.present? && refresh_lease_expires_at.present? && refresh_lease_expires_at > now
  end

  # Ciphertext (or plaintext) never leaks through inspection or error pages.
  def inspect
    "#<OauthConnection id=#{id.inspect} provider=#{provider.inspect} " \
      "state=#{state.inspect} generation=#{generation.inspect}>"
  end

  def serializable_hash(options = nil)
    super(options).except(
      "encrypted_access_token", "encrypted_refresh_token"
    )
  end
end
