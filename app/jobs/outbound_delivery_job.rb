# frozen_string_literal: true

# Control-queue delivery of one outbound action. Transient send failures stay
# pending for the recurring delivery sweep; rejections fail the action.
class OutboundDeliveryJob < ApplicationJob
  queue_as :control

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(outbound_action_id)
    Interaction::OutboundService.new.call(outbound_action_id).code.to_s
  end
end
