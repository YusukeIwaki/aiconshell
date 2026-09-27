# frozen_string_literal: true

# Cutover task for the single-execution-worker switch (issue 20).
# Run once AFTER the old control worker is stopped:
#
#   bin/rails ai_auth:revoke_legacy_control
#
# Revokes in-flight legacy control auth sessions (clearing their secrets)
# and discards stranded ai_auth_control jobs. Idempotent: safe to run
# repeatedly. Never touches execution sessions, Task/TaskRun, LayerPolicy,
# or non-auth queues, and never copies control snapshots to execution.
# Auth caches are neither copied nor deleted here; see docs/ai-connections.md.
namespace :ai_auth do
  desc "Revoke legacy control auth sessions and discard stranded ai_auth_control jobs"
  task revoke_legacy_control: :environment do
    result = AiAuth::RequestService.new.revoke_legacy_control!
    puts "revoked=#{result[:revoked]} discarded_jobs=#{result[:discarded_jobs]}"
  end
end
