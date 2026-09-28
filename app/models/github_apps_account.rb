# frozen_string_literal: true

require "digest"
require "openssl"
require "uri"

# Singleton GitHub App account (issue #28). Credentials live here, not in
# the environment. The private key is stored only as authenticated
# ciphertext; plaintext lives in memory for one operation. Only the public
# key fingerprint (non-secret) is shown back to the operator.
class GithubAppsAccount < ApplicationRecord
  API_URL_DEFAULT = "https://api.github.com"

  # Transient upload holder for the admin form; the PEM content is stored
  # encrypted via #private_key= and never persisted in this attribute.
  attr_accessor :private_key_file

  has_one :health_check_state, class_name: "GithubAppsHealthCheckState", dependent: :destroy

  before_validation :normalize_fields

  validates :app_id, format: { with: /\A\d+\z/, message: "must be numeric" }, allow_blank: true
  validates :installation_id, format: { with: /\A\d+\z/, message: "must be numeric" }, allow_blank: true
  validate :api_url_shape

  scope :ordered, -> { order(:id) }

  def self.current
    ordered.first_or_create!
  end

  def configured?
    app_id.present? && installation_id.present? && private_key.present?
  end

  def private_key?
    encrypted_private_key.present?
  end

  # Decrypted PEM text, or nil when unset or tampered. Never raises
  # through callers; tampering reads as absent and the operation fails
  # with a safe classification.
  def private_key
    raw = encrypted_private_key
    return nil if raw.nil? || raw.empty?

    decoded = Accounts::SecretBox.default.decrypt(raw)
    decoded.is_a?(String) && decoded.present? ? decoded : nil
  rescue StandardError
    nil
  end

  # Stores PEM text as ciphertext and refreshes the public fingerprint.
  # Blank input clears the stored key.
  def private_key=(pem)
    text = pem.to_s.strip
    if text.empty?
      self.encrypted_private_key = nil
      self.private_key_fingerprint = nil
    else
      self.encrypted_private_key = Accounts::SecretBox.default.encrypt(text)
      self.private_key_fingerprint = self.class.fingerprint_for(text)
    end
  end

  # True when the text parses as an RSA private key. Used to validate an
  # uploaded key file before anything is persisted.
  def self.valid_private_key?(text)
    key = OpenSSL::PKey::RSA.new(text.to_s)
    key.private?
  rescue OpenSSL::PKey::PKeyError, OpenSSL::OpenSSLError
    false
  end

  # Non-secret public key fingerprint (SHA256 over the DER public key),
  # so the operator can tell which key is stored without seeing it.
  def self.fingerprint_for(text)
    key = OpenSSL::PKey::RSA.new(text.to_s)
    "sha256:#{Digest::SHA256.hexdigest(key.public_key.to_der)}"
  rescue OpenSSL::PKey::PKeyError, OpenSSL::OpenSSLError
    nil
  end

  def api_base_url
    api_url.presence || API_URL_DEFAULT
  end

  def credential_env
    {
      "GITHUB_APP_ID" => app_id.to_s,
      "GITHUB_INSTALLATION_ID" => installation_id.to_s,
      "GITHUB_PRIVATE_KEY" => private_key.to_s,
      "GITHUB_API_URL" => api_base_url
    }
  end

  # Ciphertext (or plaintext) never leaks through inspection or error pages.
  def inspect
    "#<GithubAppsAccount id=#{id.inspect} app_id=#{app_id.inspect} " \
      "installation_id=#{installation_id.inspect} api_url=#{api_url.inspect} " \
      "key=#{private_key? ? 'set' : 'unset'}>"
  end

  def serializable_hash(options = nil)
    super(options).except("encrypted_private_key")
  end

  private

  def normalize_fields
    self.app_id = app_id.to_s.strip
    self.installation_id = installation_id.to_s.strip
    self.api_url = api_url.to_s.strip
  end

  def api_url_shape
    raw = api_url.to_s.strip
    return if raw.empty?

    uri = URI.parse(raw)
    unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      errors.add(:api_url, "must be an https URL without userinfo, query, or fragment")
    end
  rescue URI::InvalidURIError
    errors.add(:api_url, "must be an https URL without userinfo, query, or fragment")
  end
end
