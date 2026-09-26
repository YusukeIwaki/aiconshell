# frozen_string_literal: true

# Shared helpers for the admin request suite (issue 7). No Rails models
# are defined here; workflow models and ports come from the merged lanes.
module AdminTestSupport
  require "json" unless defined?(JSON)
  HOST = "app.test"
  USERNAME = "test-admin"
  PASSWORD = "test-password-for-admin-suite"
  MODERN_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " \
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

  # Sets an allowed Host, admin credentials, and Basic auth, then restores
  # everything (ENV, seams, CSRF toggle) afterwards.
  def self.as_admin(http)
    with_env(USERNAME, PASSWORD) do
      http.header "Host", HOST
      http.header "User-Agent", MODERN_UA
      http.basic_authorize USERNAME, PASSWORD
      yield
    end
  ensure
    reset_admin_seams!
  end

  def self.as_anonymous(http)
    with_env(USERNAME, PASSWORD) do
      http.header "Host", HOST
      http.header "User-Agent", MODERN_UA
      yield
    end
  ensure
    reset_admin_seams!
  end

  def self.with_env(user, pass)
    old_user = ENV["ADMIN_USERNAME"]
    old_pass = ENV["ADMIN_PASSWORD"]
    ENV["ADMIN_USERNAME"] = user
    ENV["ADMIN_PASSWORD"] = pass
    yield
  ensure
    ENV["ADMIN_USERNAME"] = old_user
    ENV["ADMIN_PASSWORD"] = old_pass
  end

  def self.reset_admin_seams!
    Admin::AiStatus.reset!
    Admin::PluginStatus.reset!
    Admin::EventLogSearch.reset!
    ActionController::Base.allow_forgery_protection = false
  end

  def self.with_forgery_protection
    old = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = old
  end

  # Fake Ai registry: configured flags per provider, no secrets anywhere.
  class FakeAiRegistry
    def initialize(configured: {})
      @configured = configured
    end

    def configured?(provider)
      !!@configured[provider.to_s]
    end

    def diagnose(provider)
      id = provider.to_s
      found = configured?(id)
      {
        id: id,
        executable: id,
        executable_found: found,
        home: "/private/#{id}",
        home_present: found,
        configured: found
      }
    end
  end

  # Fake plugins registry returning a fixed catalog.
  class FakePluginRegistry
    def initialize(catalog)
      @catalog = catalog
    end

    def catalog
      @catalog
    end
  end

  class ExplodingPluginRegistry
    def catalog
      raise RuntimeError, "plugin lane exploded"
    end
  end

  # Fake EventLog search backend recording keyword arguments.
  class FakeSearchBackend
    attr_reader :calls

    def initialize(rows)
      @rows = rows
      @calls = []
    end

    def search(**kwargs)
      @calls << kwargs
      @rows
    end
  end

  class ExplodingSearchBackend
    def search(**_kwargs)
      raise StandardError, "ClickHouse connection refused SEKRIT-DETAIL-123"
    end
  end

  # Runs the block with the REAL ClickHouseAdapter wired as the search
  # backend, but with an injected fake transport (no network). Yields the
  # list of captured transport requests. Restores the default (nil)
  # backend afterwards.
  def self.with_real_clickhouse_search(rows)
    unless defined?(Aiconshell::Observability::ClickHouseAdapter)
      require "aiconshell/observability"
    end
    requests = []
    transport = lambda do |method:, uri:, body:|
      requests << { method:, uri:, body: }
      payload = JSON.generate({ "data" => rows.map { |row| clickhouse_row(row) } })
      Aiconshell::Observability::ClickHouseAdapter::Response.new(200, payload)
    end
    adapter = Aiconshell::Observability::ClickHouseAdapter.new(
      base_url: "http://127.0.0.1:9", database: "admin_test", transport:
    )
    Aiconshell::Observability.configure { |config| config.search_backend = adapter }
    Admin::EventLogSearch.reset!
    yield requests
  ensure
    Aiconshell::Observability.reset!
    Admin::EventLogSearch.reset!
  end

  def self.clickhouse_row(row)
    {
      "event_id" => row["event_id"],
      "layer" => row["layer"],
      "kind" => row["kind"],
      "message" => row["message"],
      "data_json" => JSON.generate(row["data"] || {}),
      "task_id" => row["task_id"],
      "correlation_id" => row["correlation_id"],
      "occurred_at" => row["occurred_at"],
      "version" => row["version"] || 1
    }
  end

  def self.sample_catalog
    [
      {
        "id" => "github",
        "operations" => [
          { "name" => "latest_events", "scope" => "read", "unsupported" => false },
          { "name" => "reply", "scope" => "write", "unsupported" => false }
        ],
        "required_env" => %w[GITHUB_APP_ID GITHUB_PRIVATE_KEY],
        "configured" => false
      },
      {
        "id" => "teams",
        "operations" => [
          { "name" => "send_message", "scope" => "write", "unsupported" => false },
          { "name" => "create_issue", "scope" => nil, "unsupported" => true, "reason" => "not supported" }
        ],
        "required_env" => %w[TEAMS_TENANT_ID],
        "configured" => true
      }
    ]
  end

  def self.sample_events
    [
      {
        "event_id" => "evt-1",
        "layer" => "coordination",
        "kind" => "task.prioritized",
        "message" => "優先度を更新しました",
        "task_id" => 7,
        "correlation_id" => "corr-1",
        "occurred_at" => "2026-09-26T10:00:00Z",
        "data" => { "priority" => 10 },
        "version" => 1
      }
    ]
  end
end
