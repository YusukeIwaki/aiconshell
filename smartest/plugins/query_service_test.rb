# frozen_string_literal: true

require_relative "plugins_test_helper"

ROOT = File.expand_path("../..", __dir__) unless defined?(ROOT)
require File.join(ROOT, "app/services/interaction/plugin_access")
require File.join(ROOT, "app/services/interaction/query_service")

Plugins = Aiconshell::Plugins
QS_URL = "https://api.github.com/repos/o/r/issues?state=open&sort=created&direction=desc&per_page=30&page=1"

def qs_token_stub(transport)
  transport.stub_json("POST", "https://api.github.com/app/installations/789/access_tokens",
                      body: { "token" => "ghs_test", "expires_at" => "2026-09-26T13:00:00Z" })
end

def qs_service(registry, scopes = { "github" => ["o/r"] })
  Interaction::QueryService.new(registry: registry, allowed_scopes: scopes)
end

def qs_issue(number, title: "t", body: "b")
  { "id" => 5000 + number, "number" => number, "title" => title, "body" => body,
    "state" => "open", "labels" => [], "html_url" => "https://github.com/o/r/issues/#{number}" }
end

test("query validate preflights without I/O and call returns typed data") do |registry:, transport:|
  service = qs_service(registry)

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
  expect(service.call(plugin: "teams", operation: "create_issue",
                      input: { "scope" => "x", "title" => "t", "body" => "b" }).code)
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
  expect(transport.requests).to eq([])
end

test("query failures never include upstream text") do |registry:, transport:|
  service = qs_service(registry)
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

test("query catalog helpers expose schemas without credentials") do |registry:|
  service = qs_service(registry)

  readonly = service.read_only_catalog
  github = readonly.find { |entry| entry["id"] == "github" }
  expect(github["operations"].map { |op| op["name"] }.sort).to eq(%w[latest_events list_issues])
  expect(github["operations"][0]["input_schema"]["type"]).to eq("object")

  serialized = JSON.generate(readonly) + JSON.generate(service.catalog)
  expect(serialized).not_to include("ghs_test")
  expect(service.allowed_targets("github")).to eq(["o/r"])
  expect(service.allowed_targets["github"]).to eq(["o/r"])
end

test("query service performs no polling state writes") do
  code = File.read(File.join(ROOT, "app/services/interaction/query_service.rb"))
           .lines.reject { |line| line.strip.start_with?("#") }.join
  expect(code.include?("IntegrationCursor")).to eq(false)
  expect(code.include?("ExternalEvent")).to eq(false)
  expect(code.include?("OutboundAction")).to eq(false)
  expect(code.include?("Task")).to eq(false)
end
