# frozen_string_literal: true

# Unit-test helper. Must stay free of Rails, database, and network access:
# smartest/unit/**/*_test.rb runs with no DATABASE_URL and no app boot.
# Database-backed tests require "db_helper" instead. Register unit-safe
# fixture classes from smartest/fixtures with `use_fixture` below.
require "smartest/autorun"

Dir[File.join(__dir__, "fixtures", "**", "*.rb")].sort.each do |fixture_file|
  require fixture_file
end

Dir[File.join(__dir__, "matchers", "**", "*.rb")].sort.each do |matcher_file|
  require matcher_file
end

around_suite do |suite|
  use_matcher PredicateMatcher
  suite.run
end
