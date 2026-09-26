# frozen_string_literal: true

# Control-queue poll of one allowlisted plugin scope (recurring, 5 minutes).
# Retries transient plugin failures a bounded number of times; config errors
# are recorded on the cursor and never retried in a storm.
class InteractionPollJob < ApplicationJob
  queue_as :control

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(plugin, scope)
    result = Interaction::PollService.new.call(plugin: plugin, scope: scope)
    raise StandardError, "poll #{result.code}" if !result.ok && result.retryable

    result.code.to_s
  end
end
