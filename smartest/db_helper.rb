# frozen_string_literal: true

# Database integration-test helper. Boots Rails in RAILS_ENV=test against a
# real PostgreSQL database and registers fixtures with per-test teardown.
require "test_helper"

ENV["RAILS_ENV"] ||= "test"
ENV["RACK_ENV"] ||= ENV["RAILS_ENV"]
require_relative "../config/environment"

Dir[File.join(__dir__, "db_fixtures", "**", "*.rb")].sort.each do |fixture_file|
  require fixture_file
end

unless Rails.env.test?
  abort "db_helper requires RAILS_ENV=test (got #{Rails.env.inspect})"
end

test_database = ActiveRecord::Base.connection_db_config.database.to_s
unless test_database.end_with?("_test")
  abort "refusing to run DB tests against non-test database #{test_database.inspect} " \
    "(TEST_DATABASE_URL must point at a *_test database)"
end

around_suite do |suite|
  use_fixture RailsFixture
  suite.run
end
