# frozen_string_literal: true

# Unit-safe EventLog test support: fakes, builders, and service-connection
# helpers. No Smartest dependency, no global fixtures, no I/O at load, so
# both smartest/unit and smartest/integration tests can require it.
# (Unit fixtures live in event_log_fixtures.rb; Rails fixtures in
# integration/observability_helper.rb.)

REPO_ROOT = File.expand_path("..", __dir__) unless defined?(REPO_ROOT)
$LOAD_PATH.unshift File.join(REPO_ROOT, "lib") unless $LOAD_PATH.include?(File.join(REPO_ROOT, "lib"))

require "logger"
require "stringio"
require "timeout"
require "aiconshell/observability"

module EventLogTestSupport
  FIXED_TIME = Time.utc(2026, 9, 26, 12, 0, 0)

  class FixedClock
    def initialize(now = FIXED_TIME.dup)
      @now = now
    end

    def now
      @now
    end

    def advance_by(seconds)
      @now += seconds
    end
  end

  FakeResponse = Struct.new(:status, :body)

  # Fake ClickHouse HTTP transport: canned responses (or raised errors),
  # every request captured for assertions.
  class FakeClickHouseTransport
    attr_reader :requests

    def initialize(responses = [])
      @responses = responses
      @requests = []
    end

    def call(method:, uri:, body:)
      @requests << { method:, uri:, body: }
      next_response = @responses.shift
      raise next_response if next_response.is_a?(Exception)

      next_response || FakeResponse.new(200, "")
    end
  end

  # Fake plugins registry following the docs/architecture.md port shape.
  class FakePluginsRegistry
    attr_reader :invocations

    def initialize(catalog: nil, error: nil)
      @catalog = catalog.nil? ? [{ "id" => "teams", "configured" => true }] : catalog
      @error = error
      @invocations = []
    end

    def catalog
      @catalog
    end

    def invoke(plugin:, operation:, input:, context:)
      @invocations << { plugin:, operation:, input:, context: }
      raise @error if @error

      { "external_id" => "msg-1", "url" => nil }
    end
  end

  class FakeClickHouseSink
    attr_reader :inserted

    def initialize(error: nil)
      @error = error
      @inserted = []
    end

    def insert(envelopes)
      raise @error if @error

      @inserted.concat(envelopes)
      envelopes.size
    end
  end

  class FakeTeamsSink
    attr_reader :delivered_records

    def initialize(enabled: true, error: nil)
      @enabled = enabled
      @error = error
      @delivered_records = []
    end

    def enabled?
      @enabled
    end

    def deliver(record)
      raise @error if @error

      @delivered_records << record
      :delivered
    end
  end

  class FakeSearchBackend
    attr_reader :calls

    def initialize(results = [])
      @results = results
      @calls = []
    end

    def search(**kwargs)
      @calls << kwargs
      @results
    end
  end

  module PgConfig
    module_function

    def params
      {
        host: ENV.fetch("TEST_PG_HOST", "localhost"),
        port: ENV.fetch("TEST_PG_PORT", "55432").to_i,
        dbname: ENV.fetch("TEST_PG_DBNAME", "aiconshell_issue_5_test"),
        user: ENV.fetch("TEST_PG_USER", "postgres"),
        password: ENV.fetch("TEST_PG_PASSWORD", "aiconshell_dev")
      }
    end

    def connect(dbname: params[:dbname])
      require "pg"
      PG.connect(**params, dbname:)
    end

    def ensure_test_database!
      require "pg"
      admin = PG.connect(**params, dbname: "postgres")
      begin
        exists = admin.exec_params(
          "SELECT 1 FROM pg_database WHERE datname = $1", [params[:dbname]]
        ).ntuples == 1
        admin.exec("CREATE DATABASE #{admin.escape_identifier(params[:dbname])}") unless exists
      ensure
        admin.close
      end
    end
  end

  module ClickHouseConfig
    module_function

    def base_url = ENV.fetch("TEST_CLICKHOUSE_URL", "http://localhost:58123")
    def database = ENV.fetch("TEST_CLICKHOUSE_DATABASE", "aiconshell_issue_5_test")
    def username = ENV.fetch("TEST_CLICKHOUSE_USER", "aiconshell")
    def password = ENV.fetch("TEST_CLICKHOUSE_PASSWORD", "aiconshell_dev")

    def adapter(table: "event_log")
      Aiconshell::Observability::ClickHouseAdapter.new(
        base_url:, database:, table:, username:, password:,
        open_timeout: 5, read_timeout: 20
      )
    end

    def execute!(sql)
      execute_with_params!(sql, {})
    end

    def execute_with_params!(sql, params)
      require "net/http"
      require "uri"
      uri = URI.parse(base_url)
      uri.query = URI.encode_www_form({ "database" => database }.merge(params))
      request = Net::HTTP::Post.new(uri.request_uri)
      request.basic_auth(username, password)
      request.body = sql
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 60) do |http|
        http.request(request)
      end
      return response.body.to_s if response.code.to_i == 200

      raise "clickhouse query failed HTTP #{response.code}: #{response.body.to_s[0, 300]}"
    end

    # Drops and rebuilds `event_log` from the SHIPPED init SQL file, proving
    # the artifact itself applies cleanly.
    def rebuild_event_log_from_shipped_sql!
      execute!("DROP TABLE IF EXISTS event_log")
      execute!(File.read(File.join(REPO_ROOT, "db/clickhouse/001_create_event_log.sql")))
    end

    # Verifies server reachability AND credentials without depending on any
    # table; raises on failure so fixtures can skip cleanly.
    def ensure_test_database!
      require "net/http"
      require "uri"
      uri = URI.parse("#{base_url}/?query=#{URI.encode_www_form_component("CREATE DATABASE IF NOT EXISTS #{database}")}")
      request = Net::HTTP::Post.new(uri.request_uri)
      request.basic_auth(username, password)
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) do |http|
        http.request(request)
      end
      raise "HTTP #{response.code}: #{response.body.to_s[0, 200]}" unless response.code.to_i == 200
    end
  end

  module_function

  def build_envelope(**overrides)
    Aiconshell::Observability::Envelope.build(
      **{ layer: "coordination", kind: "task.prioritized",
          message: "Priority updated", task_id: 7,
          correlation_id: "corr-123", data: { "priority" => 10 } }.merge(overrides)
    )
  end
end
