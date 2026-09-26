# frozen_string_literal: true

require "tmpdir"

# Shared ENV isolation for workflow integration tests. Every test runs inside
# the RailsFixture db transaction (rolled back) plus an isolated execution
# root and allowlist that are restored afterwards.
module WorkflowTestHelper
  ENV_KEYS = %w[
    AICONSHELL_ALLOWED_SCOPES AICONSHELL_EXECUTION_ROOT AICONSHELL_DEMO_MODE
    AICONSHELL_LEASE_SECONDS AICONSHELL_AI_TIMEOUT_SECONDS
  ].freeze

  def with_workflow_env(scopes:, demo: false, lease_seconds: nil, ai_timeout_seconds: nil)
    saved = ENV_KEYS.to_h { |key| [key, ENV[key]] }
    Dir.mktmpdir("aiconshell-wf-") do |dir|
      ENV["AICONSHELL_ALLOWED_SCOPES"] = scopes
      ENV["AICONSHELL_EXECUTION_ROOT"] = dir
      ENV["AICONSHELL_DEMO_MODE"] = demo ? "1" : nil
      ENV["AICONSHELL_LEASE_SECONDS"] = lease_seconds&.to_s
      ENV["AICONSHELL_AI_TIMEOUT_SECONDS"] = ai_timeout_seconds&.to_s
      yield dir
    end
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

include WorkflowTestHelper
