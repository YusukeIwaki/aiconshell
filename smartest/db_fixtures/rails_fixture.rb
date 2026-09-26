# frozen_string_literal: true

require "rack/test"

# Fixtures for database integration tests (smartest/integration).
#
# Every test runs inside a database transaction that is rolled back on
# teardown, so no test can leak rows into the next one. The `http` fixture
# depends on `db`, so HTTP tests get isolation automatically; job tests
# request `db:` directly.
class RailsFixture < Smartest::Fixture
  suite_fixture :app do
    Rails.application
  end

  fixture :db do
    connection = ActiveRecord::Base.connection
    connection.begin_transaction(joinable: false)
    on_teardown { connection.rollback_transaction }
    connection
  end

  fixture :http do |db:, app:|
    # `db:` keeps the enclosing transaction (and its teardown) alive; every
    # HTTP request in the test therefore runs inside it and rolls back.
    raise "http fixture requires an open db transaction" unless db.transaction_open?
    Rack::Test::Session.new(Rack::MockSession.new(app))
  end
end
