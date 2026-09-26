source "https://rubygems.org"

ruby "3.4.9"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.0.5"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Background jobs on the same PostgreSQL database as the web app (no separate queue database)
gem "solid_queue", "~> 1.1"

# JSON Schema validation for plugin inputs/outputs and AI results
gem "json_schemer", "~> 2.5"

# ActiveSupport 8.0 calls JSON.generate(quirks_mode: ...), which json 3.x
# removed; stay on 2.x until Rails supports json 3.
gem "json", "~> 2.0"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :development, :test do
  # Load DATABASE_URL and friends from .env files (never commit .env itself)
  gem "dotenv-rails", "~> 3.1"
end

group :test do
  # Test runner with pytest-style fixtures (smartest/**/*_test.rb)
  gem "smartest", "~> 0.6.0.alpha1"
  # In-process HTTP assertions for integration tests
  gem "rack-test", "~> 2.2"
end
