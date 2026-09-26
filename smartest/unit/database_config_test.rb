# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# Unit suite: pure ERB/YAML rendering of config/database.yml under controlled
# ENV. No Rails boot, no database connection, no network.
#
# Regression coverage: ERB renders the whole file before Rails selects its env
# section, so the production branch must not fail non-production parses when
# DATABASE_URL is unset, while production itself fails closed.
DATABASE_CONFIG_PATH = File.expand_path("../../config/database.yml", __dir__)

def with_env(overrides)
  saved = overrides.keys.to_h { |key| [key, ENV[key]] }
  overrides.each { |key, value| value.nil? ? ENV.delete(key) : (ENV[key] = value) }
  yield
ensure
  saved.each { |key, value| value.nil? ? ENV.delete(key) : (ENV[key] = value) }
end

def render_database_config
  YAML.safe_load(ERB.new(File.read(DATABASE_CONFIG_PATH)).result, aliases: true)
end

test("test env resolves without DATABASE_URL") do
  with_env("RAILS_ENV" => "test",
           "DATABASE_URL" => nil,
           "TEST_DATABASE_URL" => "postgresql://localhost/aiconshell_issue_2_test") do
    config = render_database_config

    expect(config.fetch("test").fetch("url")).to eq("postgresql://localhost/aiconshell_issue_2_test")
  end
end

test("default development parse works without DATABASE_URL") do
  with_env("RAILS_ENV" => nil, "DATABASE_URL" => nil, "TEST_DATABASE_URL" => nil) do
    config = render_database_config

    expect(config.fetch("development").fetch("url")).to eq("postgresql://localhost/aiconshell_development")
  end
end

test("production without DATABASE_URL fails closed") do
  with_env("RAILS_ENV" => "production", "DATABASE_URL" => nil, "SECRET_KEY_BASE_DUMMY" => nil) do
    expect { render_database_config }.to raise_error(KeyError, /DATABASE_URL is required in production/)
  end
end

test("production with an explicit DATABASE_URL resolves") do
  with_env("RAILS_ENV" => "production", "DATABASE_URL" => "postgresql://db/aiconshell_production") do
    config = render_database_config

    expect(config.fetch("production").fetch("url")).to eq("postgresql://db/aiconshell_production")
  end
end

test("production asset precompilation without DATABASE_URL is exempt") do
  with_env("RAILS_ENV" => "production", "DATABASE_URL" => nil, "SECRET_KEY_BASE_DUMMY" => "1") do
    config = render_database_config

    expect(config.fetch("production").fetch("url")).to eq("postgresql://localhost/aiconshell_production_unused")
  end
end
