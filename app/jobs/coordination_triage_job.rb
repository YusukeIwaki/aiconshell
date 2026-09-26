# frozen_string_literal: true

# Control-queue triage of the durable inbox and pending feedback (recurring).
class CoordinationTriageJob < ApplicationJob
  queue_as :control

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(batch_limit: 50)
    result = Coordination::TriageService.new.call(batch_limit: batch_limit)
    "ingested=#{result.ingested} triaged=#{result.triaged} rejected=#{result.rejected}"
  end
end
