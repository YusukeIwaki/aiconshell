# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/aiconshell/oauth"

test("token set validates exchange payloads strictly") do
  validated = Aiconshell::Oauth::TokenSet.validate_exchange!(
    { "access_token" => "at-1", "refresh_token" => "rt-1", "expires_in" => "3600",
      "scope" => "offline_access  User.Read,User.Read" },
    provider: "microsoft"
  )

  expect(validated["access_token"]).to eq("at-1")
  expect(validated["expires_in"]).to eq(3600)
  expect(validated["scope"]).to eq("offline_access User.Read")

  [nil, "oops", [], { "access_token" => 42, "expires_in" => 10 },
   { "access_token" => "at", "expires_in" => 1.5 }].each do |bad|
    raised = nil
    begin
      Aiconshell::Oauth::TokenSet.validate_exchange!(bad, provider: "atlassian")
    rescue Aiconshell::Oauth::ProviderError => e
      raised = e
    end
    expect(raised.nil?).to eq(false)
    expect(raised.code).to eq("unexpected_response")
  end
end

test("scope coverage is exact and case-sensitive") do
  set = Aiconshell::Oauth::TokenSet

  expect(set.granted_scopes?("offline_access User.Read", ["offline_access", "User.Read"])).to eq(true)
  expect(set.granted_scopes?("offline_access", ["offline_access", "User.Read"])).to eq(false)
  expect(set.granted_scopes?("offline_access user.read", ["User.Read"])).to eq(false)
  expect(set.error_code_from_payload({ "error" => "invalid_grant" })).to eq("invalid_grant")
  expect(set.error_code_from_payload({ "error" => "invalid_request" })).to eq("provider_rejected")
  expect(set.error_code_from_payload({ "error" => "weird_future_code" })).to eq("provider_rejected")
  expect(set.error_code_from_payload({})).to eq(nil)
  expect(set.error_code_from_payload(nil)).to eq(nil)
end

def sample_binding(overrides = {})
  {
    "connection_id" => 7,
    "generation" => 3,
    "provider" => "atlassian",
    "principal" => "acc-123",
    "tenant" => nil,
    "cloud" => "cloud-1"
  }.merge(overrides)
end

test("bindings match only the identical stored snapshot") do
  binding = Aiconshell::Oauth::Binding.from_h(sample_binding)

  expect(binding.matches?(sample_binding)).to eq(true)
  expect(binding.matches?(sample_binding("generation" => 4))).to eq(false)
  expect(binding.matches?(sample_binding("principal" => "acc-999"))).to eq(false)
  expect(binding.matches?(sample_binding("provider" => "microsoft"))).to eq(false)
  expect(binding.matches?(sample_binding("connection_id" => 8))).to eq(false)
  expect(binding.matches?(sample_binding("cloud" => "cloud-2"))).to eq(false)
  expect(binding.matches?(nil)).to eq(false)
  expect(binding.matches?("oops")).to eq(false)
end

test("bindings carry no secrets and redact inspection") do
  binding = Aiconshell::Oauth::Binding.from_h(sample_binding)
  shown = binding.to_h

  expect(shown.keys.sort).to eq(%w[cloud connection_id generation principal provider tenant])
  expect(shown.values.join.include?("token")).to eq(false)
  expect(binding.inspect.include?("acc-123")).to eq(false)
  expect(binding.inspect.include?("atlassian")).to eq(true)
end
