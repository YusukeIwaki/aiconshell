# frozen_string_literal: true

require "test_helper"
require "json_schemer"

# Unit suite: pure validation logic, no Rails boot, no database, no network.
# Locks in the json_schemer API the plugin/AI lanes will build on.
test("accepts input matching the schema") do
  schemer = JSONSchemer.schema({
    "type" => "object",
    "required" => %w[scope cursor],
    "properties" => {
      "scope" => { "type" => "string", "minLength" => 1 },
      "cursor" => { "type" => %w[object null] }
    }
  })

  expect(schemer.valid?({ "scope" => "issues", "cursor" => nil })).to eq(true)
end

test("rejects input violating the schema with errors") do
  schemer = JSONSchemer.schema({
    "type" => "object",
    "required" => %w[scope],
    "properties" => { "scope" => { "type" => "string", "minLength" => 1 } }
  })

  errors = schemer.validate({ "scope" => "" }).to_a

  expect(errors).not_to eq([])
  expect(errors.first.fetch("type")).to eq("minLength")
  expect(errors.first.fetch("data_pointer")).to eq("/scope")
end
