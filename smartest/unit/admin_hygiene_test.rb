# frozen_string_literal: true

require "test_helper"

# Static guard for the Interaction/Coordination/Execution split: admin
# controllers accept feedback and configure policies, but never invoke
# execution workers, never mutate tasks/runs, and never shell out.
ADMIN_CONTROLLERS_DIR = File.expand_path("../../app/controllers/admin", __dir__)
ADMIN_ROUTES_FILE = File.expand_path("../../config/routes/admin.rb", __dir__)

FORBIDDEN_TOKENS = [
  "perform_later",
  "perform_now",
  "SolidQueue",
  "ActiveJob",
  ".dispatch",
  "TaskRun.create",
  "TaskRun.new",
  "Task.create",
  "Task.new",
  ".update(",
  ".update!(",
  ".destroy",
  ".delete(",
  "system(",
  "exec(",
  "eval(",
  "`"
].freeze

test("admin controllers contain no worker dispatch or task mutation") do
  files = Dir[File.join(ADMIN_CONTROLLERS_DIR, "*.rb")].sort
  expect(files.empty?).to eq(false)

  violations = []
  files.each do |file|
    source = File.read(file)
    FORBIDDEN_TOKENS.each do |token|
      violations << "#{File.basename(file)}: #{token}" if source.include?(token)
    end
  end

  expect(violations).to eq([])
end

test("admin routes expose no run/dispatch/execute endpoints") do
  source = File.read(ADMIN_ROUTES_FILE)

  expect(source.include?("feedbacks")).to eq(true)
  %w[run dispatch execute perform enqueue].each do |token|
    expect(source.match?(/\b#{token}\b/)).to eq(false)
  end
end
