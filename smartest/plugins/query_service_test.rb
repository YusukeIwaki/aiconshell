# frozen_string_literal: true

require_relative "plugins_test_helper"

ROOT = File.expand_path("../..", __dir__) unless defined?(ROOT)
require File.join(ROOT, "app/services/accounts")
require File.join(ROOT, "app/services/interaction/plugin_access")
require File.join(ROOT, "app/services/interaction/query_service")

Plugins = Aiconshell::Plugins
QS_URL = "https://api.github.com/repos/o/r/issues?state=open&sort=created&direction=desc&per_page=30&page=1"

def qs_token_stub(transport)
  transport.stub_json("POST", "https://api.github.com/app/installations/789/access_tokens",
                      body: { "token" => "ghs_test", "expires_at" => "2026-09-26T13:00:00Z" })
end

# Standalone stand-in for the database-backed Accounts source (unit tests
# never touch the database): the same env hash the registry was built with.
class FakeCredentialSource
  def initialize(env)
    @env = env
  end

  def env_for(_plugin)
    @env
  end
end

def qs_service(registry, scopes = { "github" => ["o/r"] }, env = {})
  Interaction::QueryService.new(registry: registry, allowed_scopes: scopes, event_sink: nil,
    credential_source: FakeCredentialSource.new(env))
end

def qs_issue(number, title: "t", body: "b")
  { "id" => 5000 + number, "number" => number, "title" => title, "body" => body,
    "state" => "open", "labels" => [], "html_url" => "https://github.com/o/r/issues/#{number}" }
end

test("query validate preflights without I/O and call returns typed data") do |registry:, transport:, plugin_env:|
  service = qs_service(registry, { "github" => ["o/r"] }, plugin_env)

  preflight = service.validate(plugin: "github", operation: "list_issues",
                               input: { "scope" => "o/r" })
  expect(preflight.ok?).to eq(true)
  expect(preflight.code).to eq(:ok)
  expect(preflight.data).to eq(nil)
  expect(transport.requests).to eq([])

  qs_token_stub(transport)
  transport.stub_json("GET", QS_URL, body: [qs_issue(1, title: "hello", body: "world")])

  result = service.call(plugin: "github", operation: "list_issues",
                        input: { "scope" => "o/r" })
  expect(result.ok?).to eq(true)
  expect(result.code).to eq(:ok)
  expect(result.data["issues"].size).to eq(1)
  expect(result.data["issues"][0]["title"]).to eq("hello")
  expect(result.data["complete"]).to eq(true)
end

test("query rejects writes, unknown, and unsupported before transport") do |registry:, transport:|
  service = qs_service(registry)

  %w[reply create_issue].each do |operation|
    input = operation == "reply" ? { "resource_id" => "issue:o/r#1", "body" => "hi" } :
                                   { "scope" => "o/r", "title" => "t", "body" => "b" }
    expect(service.validate(plugin: "github", operation: operation, input: input).code).to eq(:not_read_only)
    result = service.call(plugin: "github", operation: operation, input: input)
    expect(result.ok?).to eq(false)
    expect(result.code).to eq(:not_read_only)
    expect(result.data).to eq(nil)
  end

  expect(service.call(plugin: "nope", operation: "list_issues",
                      input: { "scope" => "o/r" }).code).to eq(:unknown_plugin)
  expect(service.call(plugin: "github", operation: "destroy",
                      input: {}).code).to eq(:unknown_operation)
  expect(service.call(plugin: "discord", operation: "create_issue",
                      input: { "scope" => "channel:123", "title" => "t", "body" => "b" }).code)
    .to eq(:unsupported_operation)
  expect(transport.requests).to eq([])
end

test("query rejects schema violations and disallowed scopes with zero network") do |registry:, transport:|
  service = qs_service(registry)

  bad_inputs = [
    { "scope" => 42 },
    { "scope" => "o/r", "extra" => true },
    "not-a-hash"
  ]
  bad_inputs.each do |input|
    expect(service.validate(plugin: "github", operation: "list_issues", input: input).code).to eq(:input_invalid)
    expect(service.call(plugin: "github", operation: "list_issues", input: input).code).to eq(:input_invalid)
  end

  denied = qs_service(registry, { "github" => ["other/repo"] })
  expect(denied.validate(plugin: "github", operation: "list_issues",
                         input: { "scope" => "o/r" }).code).to eq(:scope_not_allowed)
  expect(denied.call(plugin: "github", operation: "list_issues",
                     input: { "scope" => "o/r" }).code).to eq(:scope_not_allowed)
  expect(transport.requests).to eq([])
end

test("query maps plugin-level scope and cursor failures to safe codes") do |registry:, transport:|
  service = qs_service(registry, { "github" => ["o/r", "bad scope"] })

  result = service.call(plugin: "github", operation: "list_issues",
                        input: { "scope" => "bad scope" })
  expect(result.ok?).to eq(false)
  expect(result.code).to eq(:input_invalid)
  expect(transport.requests).to eq([])

  result = service.call(plugin: "github", operation: "list_issues",
                        input: { "scope" => "o/r",
                                 "cursor" => { "version" => 1, "scope" => "evil/r", "page" => 2 } })
  expect(result.code).to eq(:input_invalid)
  expect(service.validate(plugin: "github", operation: "list_issues",
    input: { "scope" => "o/r", "cursor" => { "version" => 1, "scope" => "evil/r", "page" => 2 } }).code).to eq(:input_invalid)
  expect(transport.requests).to eq([])
end

test("registry pure preflight normalizes input and rejects semantic cursors before transport") do |registry:, transport:|
  value = registry.validate_input(plugin: "github", operation: "list_issues",
    input: { scope: "o/r", cursor: nil }, context: { "scopes" => ["github:read"] })
  expect(value).to eq({ "scope" => "o/r", "cursor" => nil })
  expect do
    registry.validate_input(plugin: "github", operation: "list_issues",
      input: { "scope" => "o/r", "cursor" => { "version" => 1, "scope" => "elsewhere/repo", "page" => 2 } })
  end.to raise_error(Plugins::InputInvalid)
  expect(transport.requests).to eq([])
end

test("query rejects truly recursive input safely") do |registry:, transport:|
  input = { "scope" => "o/r" }
  input["cursor"] = input
  expect(qs_service(registry).validate(plugin: "github", operation: "list_issues", input: input).code).to eq(:input_invalid)
  expect(transport.requests).to eq([])
end

test("custom read operation uses schema-only preflight and bounded validated output") do
  custom = Class.new(Plugins::Base) do
    plugin_id "query_example"
    operation "inspect", read_only: true, scope: "query_example:read",
      input_schema: Plugins::Schemas::LATEST_EVENTS_INPUT,
      output_schema: { "type" => "object", "required" => ["text"], "additionalProperties" => false,
                       "properties" => { "text" => { "type" => "string" } } }
    attr_reader :calls
    def initialize
      @calls = 0
    end
    def handle_inspect(input, _ctx)
      @calls += 1
      { "text" => "x" * (input["scope"] == "large" ? 128_001 : 2) }
    end
  end.new
  registry = Plugins::Registry.new(env: {}, transport: Object.new).register(custom)
  service = qs_service(registry, { "query_example" => %w[small large] })
  expect(service.validate(plugin: "query_example", operation: "inspect", input: { "scope" => "small" }).ok?).to eq(true)
  expect(custom.calls).to eq(0)
  expect(service.call(plugin: "query_example", operation: "inspect", input: { "scope" => "small" }).data).to eq({ "text" => "xx" })
  result = service.call(plugin: "query_example", operation: "inspect", input: { "scope" => "large" })
  expect(result.code).to eq(:output_too_large)
  expect(result.data).to eq(nil)
end

test("query rejects a declared operation without complete schemas") do
  custom = Class.new(Plugins::Base) do
    plugin_id "invalid_contract"
    operation "inspect", read_only: true, input_schema: Plugins::Schemas::LATEST_EVENTS_INPUT, output_schema: nil
    def handle_inspect(*) = raise("handler must not run")
  end.new
  registry = Plugins::Registry.new(env: {}, transport: Object.new).register(custom)
  service = qs_service(registry, { "invalid_contract" => ["target"] })
  expect(service.validate(plugin: "invalid_contract", operation: "inspect", input: { "scope" => "target" }).code).to eq(:schema_invalid)
end

test("query failures never include upstream text") do |registry:, transport:, plugin_env:|
  service = qs_service(registry, { "github" => ["o/r"] }, plugin_env)
  qs_token_stub(transport)
  transport.stub_json("GET", QS_URL, status: 500, body: { "message" => "secret leak attempt" })

  result = service.call(plugin: "github", operation: "list_issues",
                        input: { "scope" => "o/r" })
  expect(result.ok?).to eq(false)
  expect(result.data).to eq(nil)
  serialized = JSON.generate({ ok: result.ok?, code: result.code, data: result.data })
  expect(serialized).not_to include("secret")
  expect(serialized).not_to include("leak")
end

test("query event metadata does not echo unknown AI supplied operation names") do |registry:|
  sink = Object.new
  events = []
  sink.define_singleton_method(:emit) { |**event| events << event }
  service = Interaction::QueryService.new(registry: registry, allowed_scopes: {},
    event_sink: sink, credential_source: FakeCredentialSource.new({}))
  expect(service.call(plugin: "secret request text", operation: "private message", input: {}).code).to eq(:unknown_plugin)
  expect(events.size).to eq(1)
  expect(events.first[:data]).to eq({ plugin: "unknown", operation: "unknown", code: "unknown_plugin" })
end

test("query catalog helpers expose schemas without credentials") do |registry:|
  service = qs_service(registry)

  readonly = service.read_only_catalog
  github = readonly.find { |entry| entry["id"] == "github" }
  expect(github["operations"].map { |op| op["name"] }.sort).to eq(%w[health_check latest_events list_issues])
  expect(github["operations"][0]["input_schema"]["type"]).to eq("object")

  serialized = JSON.generate(readonly) + JSON.generate(service.catalog)
  expect(serialized).not_to include("ghs_test")
  expect(service.allowed_targets("github")).to eq(["o/r"])
  expect(service.allowed_targets["github"]).to eq(["o/r"])
end

test("query uses the credential source only, never registry env") do |registry:, transport:|
  # The registry itself carries full fake credentials; an empty source must
  # still fail closed: the registry environment is never a fallback.
  service = qs_service(registry)
  qs_token_stub(transport)
  transport.stub_json("GET", QS_URL, body: [])

  result = service.call(plugin: "github", operation: "list_issues",
                        input: { "scope" => "o/r" })
  expect(result.ok?).to eq(false)
  expect(result.code).to eq(:credentials_missing)
  expect(transport.requests).to eq([])
end

test("query service performs no polling state writes") do
  code = File.read(File.join(ROOT, "app/services/interaction/query_service.rb"))
           .lines.reject { |line| line.strip.start_with?("#") }.join
  expect(code.include?("IntegrationCursor")).to eq(false)
  expect(code.include?("ExternalEvent")).to eq(false)
  expect(code.include?("OutboundAction")).to eq(false)
  expect(code.include?("Task")).to eq(false)
end
