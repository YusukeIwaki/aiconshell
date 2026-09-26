# frozen_string_literal: true

require "fileutils"

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
      if Rails.env.production? && ENV["AICONSHELL_EXECUTION_ROOT"].to_s.empty?
        raise ArgumentError, "AICONSHELL_EXECUTION_ROOT is required in production"
      end
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
      positive_integer("AICONSHELL_LEASE_SECONDS", 1800)
    end

    def ai_timeout_seconds
      positive_integer("AICONSHELL_AI_TIMEOUT_SECONDS", 600)
    end

    def poll_lease_seconds
      positive_integer("AICONSHELL_POLL_LEASE_SECONDS", 300)
    end

    def max_run_attempts
      positive_integer("AICONSHELL_MAX_RUN_ATTEMPTS", 3)
    end

    def max_action_attempts
      positive_integer("AICONSHELL_MAX_ACTION_ATTEMPTS", 5)
    end

    def demo_mode?
      ENV["AICONSHELL_DEMO_MODE"] == "1"
    end

    # Include a shutdown margin; correctness never depends on heartbeat
    # callbacks from a blocking provider adapter.
    def lease_covers_ai_runtime?
      lease_seconds > ai_timeout_seconds + 10
    end

    def validate!
      raise ArgumentError, "execution lease must exceed AI timeout plus 10 seconds for shutdown" unless lease_covers_ai_runtime?

      poll_lease_seconds
      max_run_attempts
      max_action_attempts
      execution_root
      true
    end

    # Resolve the root and each application-generated child canonically;
    # reject symlinks before creating any directory beneath them.
    def workspace(*segments)
      root = File.expand_path(execution_root)
      raise ArgumentError, "execution root cannot be filesystem root" if root == "/"

      FileUtils.mkdir_p(root, mode: 0o700)
      root = File.realpath(root)
      raise ArgumentError, "execution root cannot be filesystem root" if root == "/"

      segments.reduce(root) do |parent, segment|
        raise ArgumentError, "invalid workspace segment" unless segment.to_s.match?(/\A[a-zA-Z0-9_-]+\z/)

        child = File.join(parent, segment.to_s)
        raise ArgumentError, "workspace symlink rejected" if File.symlink?(child)

        begin
          Dir.mkdir(child, 0o700)
        rescue Errno::EEXIST
          raise ArgumentError, "workspace is not a directory" unless File.directory?(child)
        end
        canonical = File.realpath(child)
        unless !File.symlink?(child) && canonical.start_with?("#{root}/")
          raise ArgumentError, "workspace escaped execution root"
        end
        canonical
      end
    end

    private

    def positive_integer(key, default)
      value = Integer(ENV.fetch(key, default.to_s), 10)
      raise ArgumentError, "#{key} must be positive" unless value.positive?

      value
    end
  end
end
