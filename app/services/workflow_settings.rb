# frozen_string_literal: true

# Operator-configured workflow settings (issue #6). All values come from the
# environment or Rails config; nothing is trusted from human/AI text.
#
#   AICONSHELL_EXECUTION_ROOT  required in production; workspaces are created
#                              underneath it. Never an arbitrary path.
#   AICONSHELL_ALLOWED_SCOPES  comma-separated "plugin:scope" allowlist used
#                              for polling and outbound actions.
#   AICONSHELL_LEASE_SECONDS   execution lease (default 1800). Must exceed
#                              AICONSHELL_AI_TIMEOUT_SECONDS.
#   AICONSHELL_AI_TIMEOUT_SECONDS bounded AI runtime (default 600).
#   AICONSHELL_DEMO_MODE       "1" enables the explicit deterministic
#                              triage fallback only. Never silent in prod.
class WorkflowSettings
  class << self
    def execution_root
      ENV.fetch("AICONSHELL_EXECUTION_ROOT", Rails.root.join("tmp/ai_workspaces").to_s)
    end

    # {"github" => ["owner/repo"], ...}
    def allowed_scopes
      raw = ENV.fetch("AICONSHELL_ALLOWED_SCOPES", "")
      out = Hash.new { |h, k| h[k] = [] }
      raw.split(",").each do |entry|
        plugin, scope = entry.strip.split(":", 2)
        next if plugin.nil? || plugin.empty? || scope.nil? || scope.empty?

        out[plugin] |= [scope]
      end
      out
    end

    def scope_allowed?(plugin, scope)
      allowed_scopes.fetch(plugin.to_s, []).include?(scope.to_s)
    end

    def lease_seconds
      ENV.fetch("AICONSHELL_LEASE_SECONDS", "1800").to_i
    end

    def ai_timeout_seconds
      ENV.fetch("AICONSHELL_AI_TIMEOUT_SECONDS", "600").to_i
    end

    def poll_lease_seconds
      ENV.fetch("AICONSHELL_POLL_LEASE_SECONDS", "300").to_i
    end

    def max_run_attempts
      ENV.fetch("AICONSHELL_MAX_RUN_ATTEMPTS", "3").to_i
    end

    def max_action_attempts
      ENV.fetch("AICONSHELL_MAX_ACTION_ATTEMPTS", "5").to_i
    end

    def demo_mode?
      ENV["AICONSHELL_DEMO_MODE"] == "1"
    end

    # Lease must exceed bounded AI runtime so a healthy run never loses its
    # lease mid-call; otherwise heartbeats must extend it (see runner).
    def lease_covers_ai_runtime?
      lease_seconds > ai_timeout_seconds
    end
  end
end
