# frozen_string_literal: true

require "db_helper"

test("web and queue share a single database") do |db:|
  expect(db.transaction_open?).to eq(true)

  names = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).map(&:name)

  expect(names).to eq([ "primary" ])
  expect(Rails.application.config.active_job.queue_adapter).to eq(:solid_queue)
end

test("lib/aiconshell is explicitly required, never autoloaded") do |db:|
  expect(db.transaction_open?).to eq(true)

  managed = Rails.autoloaders.main.dirs.map(&:to_s)

  expect(managed.any? { |dir| dir.end_with?("lib/aiconshell") }).to eq(false)
  expect($LOAD_PATH.any? { |dir| dir.end_with?("lib") }).to eq(true)
end
