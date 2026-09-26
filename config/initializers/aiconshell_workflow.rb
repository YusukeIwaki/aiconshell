# frozen_string_literal: true

# Operator setup for the issue #6 workflow (see docs/workflow.md).
# Creates the execution root in development/test; production fails closed
# when AICONSHELL_EXECUTION_ROOT is missing.
Rails.application.config.after_initialize do
  root = WorkflowSettings.execution_root
  if Rails.env.production? && ENV["AICONSHELL_EXECUTION_ROOT"].to_s.empty?
    Rails.logger.error("[workflow] AICONSHELL_EXECUTION_ROOT is not configured")
  else
    begin
      FileUtils.mkdir_p(root)
    rescue StandardError => e
      Rails.logger.warn("[workflow] cannot create execution root: #{e.class}")
    end
  end

  unless WorkflowSettings.lease_covers_ai_runtime?
    Rails.logger.warn(
      "[workflow] lease (#{WorkflowSettings.lease_seconds}s) does not exceed " \
      "AI timeout (#{WorkflowSettings.ai_timeout_seconds}s); heartbeats are required"
    )
  end
end
