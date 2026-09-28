# frozen_string_literal: true

require "aiconshell/plugins" unless defined?(Aiconshell::Plugins::Registry)

module Accounts
  # Runs an account health check (issue #28): invokes the plugin's
  # read-only health_check operation with database-backed credentials and
  # records the outcome on the account's health check state row
  # (updated_at becomes the last check time). Failures carry only a
  # content-free code; provider text is never persisted.
  class HealthCheck
    Result = Struct.new(:ok, :code, :missing, keyword_init: true) do
      def ok?
        !!ok
      end
    end

    class << self
      # Test seam: inject a fake transport responding to #request.
      attr_accessor :test_transport

      def call(plugin:, registry: nil, transport: nil, clock: Time)
        plugin_name = plugin.to_s
        account = ensure_account(plugin_name)
        return Result.new(ok: false, code: :unknown_plugin, missing: []) if account.nil?

        registry ||= Aiconshell::Plugins::Registry.default
        context = Accounts.invoke_context(plugin_name, "health_check", registry: registry)
        context = context.merge("transport" => (transport || test_transport)) unless (transport || test_transport).nil?

        output = registry.invoke(plugin: plugin_name, operation: "health_check", input: {}, context: context)
        unless output.is_a?(Hash) && output["ok"] == true
          missing = output.is_a?(Hash) && output["missing"].is_a?(Array) ? output["missing"].map(&:to_s) : []
          record(account, ok: false, code: "missing_permissions")
          return Result.new(ok: false, code: :missing_permissions, missing: missing)
        end
        record(account, ok: true, code: nil)
        Result.new(ok: true, code: :ok, missing: [])
      rescue Aiconshell::Plugins::CredentialsMissing
        record(account, ok: false, code: "credentials_missing") if account
        Result.new(ok: false, code: :credentials_missing, missing: [])
      rescue Aiconshell::Plugins::RateLimited
        record(account, ok: false, code: "rate_limited") if account
        Result.new(ok: false, code: :rate_limited, missing: [])
      rescue Aiconshell::Plugins::HttpError => error
        code = (error.respond_to?(:status) && [401, 403].include?(error.status.to_i)) ? "unauthorized" : "upstream_error"
        record(account, ok: false, code: code) if account
        Result.new(ok: false, code: code.to_sym, missing: [])
      rescue Aiconshell::Plugins::TransportError, Aiconshell::Plugins::TransportTimeout,
             Aiconshell::Plugins::OutputInvalid, Aiconshell::Plugins::IncompletePoll
        record(account, ok: false, code: "upstream_error") if account
        Result.new(ok: false, code: :upstream_error, missing: [])
      rescue StandardError
        record(account, ok: false, code: "internal_error") if account
        Result.new(ok: false, code: :internal_error, missing: [])
      end

      private

      # An explicit operator check always has a record target: the
      # singleton row is created on demand so the outcome (including
      # credentials_missing) is visible in the admin UI. Unknown
      # plugins still return nil. Unlike Accounts.account_for (which
      # stays read-only for implicit poll/query paths), creating here
      # is safe because the operator explicitly ran the check.
      def ensure_account(plugin_name)
        case plugin_name
        when "github" then GithubAppsAccount.current
        when "discord" then DiscordAccount.current
        end
      end

      def record(account, ok:, code:)
        state = account.health_check_state || account.build_health_check_state
        state.status = ok ? "ok" : "error"
        state.error_code = code
        state.save!
      end
    end
  end
end
