# frozen_string_literal: true

require "db_helper"

# Test-only job (not a domain model): proves enqueue writes a Solid Queue row
# and that the stored payload performs, the same way a worker executes it.
class QueueSmokeJob < ActiveJob::Base
  queue_as :default

  cattr_accessor :performed, default: []

  def perform(value)
    self.class.performed << value
  end
end

test("perform_later enqueues a Solid Queue row") do |db:|
  expect(db.transaction_open?).to eq(true)
  QueueSmokeJob.performed.clear

  job = QueueSmokeJob.perform_later("hello")

  record = SolidQueue::Job.find_by(active_job_id: job.job_id)
  expect(record.nil?).to eq(false)
  expect(record.class_name).to eq("QueueSmokeJob")
  expect(record.ready_execution.nil?).to eq(false)
end

test("enqueued payload performs like a worker execution") do |db:|
  expect(db.transaction_open?).to eq(true)
  QueueSmokeJob.performed.clear

  job = QueueSmokeJob.perform_later("hello")
  record = SolidQueue::Job.find_by(active_job_id: job.job_id)

  # Same call a Solid Queue worker makes (see ClaimedExecution#perform).
  ActiveJob::Base.execute(record.arguments.merge("provider_job_id" => record.id))

  expect(QueueSmokeJob.performed).to eq([ "hello" ])
end
