# frozen_string_literal: true

require "test_helper"

# Unit suite: static layer-boundary checks. No Rails boot; the workflow lane
# owns app/services/{interaction,coordination,execution} and app/jobs, and
# these files must keep Interaction/Coordination/Execution separate even as
# parallel lanes add controllers and plugins.
ROOT = File.expand_path("../../..", __dir__) unless defined?(ROOT)

def workflow_files(relative)
  Dir[File.join(ROOT, relative)].sort
end

def read_all(paths)
  paths.to_h { |path| [path, File.read(path)] }
end

test("execution services never mutate tasks or call plugins") do
  sources = read_all(workflow_files("app/services/execution/**/*.rb"))
  expect(sources.empty?).to eq(false)

  violations = []
  sources.each do |path, source|
    %w[Task. task.update transition_to! Plugins::Registry registry.invoke].each do |marker|
      violations << "#{path} contains #{marker}" if source.include?(marker)
    end
  end
  expect(violations).to eq([])
end

test("controllers never invoke the execution worker directly") do
  controller_files = workflow_files("app/controllers/**/*.rb")
  service_files = workflow_files("app/services/{interaction,coordination}/**/*.rb")
  # Controllers are owned by the admin lane and may not exist yet; the
  # invariant covers both present controllers and interaction/coordination
  # services, which must never perform execution work themselves.
  sources = read_all(controller_files + service_files)
  expect(sources.empty?).to eq(false)

  violations = []
  sources.each do |path, source|
    %w[ExecutionRunJob Execution::RunnerService].each do |marker|
      # Coordination dispatch is the single allowed enqueuer.
      next if path.end_with?("coordination/dispatch_service.rb") && marker == "ExecutionRunJob"
      next if path.end_with?("coordination/recovery_service.rb") && marker == "ExecutionRunJob"

      violations << "#{path} contains #{marker}" if source.include?(marker)
    end
  end
  expect(violations).to eq([])

  dispatch_sources = read_all(workflow_files("app/services/coordination/**/*.rb")).values.join("\n")
  expect(dispatch_sources.include?("ExecutionRunJob")).to eq(true)
end

test("no shell interpolation of prompts or event text in workflow services") do
  sources = read_all(workflow_files("app/services/**/*.rb"))
  expect(sources.empty?).to eq(false)

  violations = sources.filter_map do |path, source|
    path if source.match?(/`#\{|%x[(\[{]|system\(|Open3\.|[^_]exec\(/)
  end
  expect(violations).to eq([])
end

test("layer policies persist no secrets") do
  code = File.read(File.join(ROOT, "app/models/layer_policy.rb"))
         .lines.reject { |line| line.strip.start_with?("#") }.join
  migration = File.read(Dir[File.join(ROOT, "db/migrate/*create_workflow_tables.rb")].first)
                .lines.reject { |line| line.strip.start_with?("#") }.join

  expect(code.match?(/token|secret|password|api[_-]?key/i)).to eq(false)
  expect(migration.match?(/layer_policies.*token|token.*layer/i)).to eq(false)
end
