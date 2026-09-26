# frozen_string_literal: true

require "json_schemer"

module Aiconshell
  module Plugins
    # Shared JSON Schemas for the operation contracts defined in
    # docs/architecture.md ("Plugins"). Every adapter reuses these shapes so
    # inputs and outputs stay uniform across plugins. Schemas use plain
    # String-keyed Hashes; validated with the json_schemer gem.
    module Schemas
      ISO8601_PATTERN =
        '\\A\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?(Z|[+-]\\d{2}:?\\d{2})\\z'

      # latest_events input: {"scope": "...", "cursor": null | object}.
      LATEST_EVENTS_INPUT = {
        "type" => "object",
        "required" => %w[scope],
        "properties" => {
          "scope" => { "type" => "string", "minLength" => 1 },
          "cursor" => { "type" => %w[object null] }
        },
        "additionalProperties" => false
      }.freeze

      EVENT = {
        "type" => "object",
        "required" => %w[
          event_id fingerprint event_type resource_id
          actor_id actor_type occurred_at payload
        ],
        "properties" => {
          "event_id" => { "type" => "string", "minLength" => 1 },
          "fingerprint" => { "type" => "string", "minLength" => 1 },
          "event_type" => { "type" => "string", "minLength" => 1 },
          "resource_id" => { "type" => "string", "minLength" => 1 },
          "actor_id" => { "type" => "string", "minLength" => 1 },
          "actor_type" => { "type" => "string", "enum" => %w[human bot system] },
          "occurred_at" => { "type" => "string", "pattern" => ISO8601_PATTERN },
          "payload" => { "type" => "object" }
        },
        "additionalProperties" => false
      }.freeze

      # latest_events output: {"events": [...], "cursor": {...}}.
      LATEST_EVENTS_OUTPUT = {
        "type" => "object",
        "required" => %w[events cursor],
        "properties" => {
          "events" => { "type" => "array", "items" => EVENT },
          "cursor" => { "type" => "object" }
        },
        "additionalProperties" => false
      }.freeze

      # reply input: {"resource_id": "...", "body": "..."}.
      REPLY_INPUT = {
        "type" => "object",
        "required" => %w[resource_id body],
        "properties" => {
          "resource_id" => { "type" => "string", "minLength" => 1 },
          "body" => { "type" => "string", "minLength" => 1, "maxLength" => 65_536 }
        },
        "additionalProperties" => false
      }.freeze

      # create_issue input: {"scope": "...", "title": "...", "body": "..."}.
      CREATE_ISSUE_INPUT = {
        "type" => "object",
        "required" => %w[scope title body],
        "properties" => {
          "scope" => { "type" => "string", "minLength" => 1 },
          "title" => { "type" => "string", "minLength" => 1, "maxLength" => 512 },
          "body" => { "type" => "string", "minLength" => 1, "maxLength" => 65_536 }
        },
        "additionalProperties" => false
      }.freeze

      # send_message input (Teams): {"scope": "...", "body": "..."}.
      SEND_MESSAGE_INPUT = {
        "type" => "object",
        "required" => %w[scope body],
        "properties" => {
          "scope" => { "type" => "string", "minLength" => 1 },
          "body" => { "type" => "string", "minLength" => 1, "maxLength" => 65_536 }
        },
        "additionalProperties" => false
      }.freeze

      # Write result: {"external_id": "...", "url": null | string}.
      WRITE_OUTPUT = {
        "type" => "object",
        "required" => %w[external_id url],
        "properties" => {
          "external_id" => { "type" => "string", "minLength" => 1 },
          "url" => { "type" => %w[string null] }
        },
        "additionalProperties" => false
      }.freeze

      class << self
        # Human-readable validation failures, empty when data is valid.
        def error_details(schema, data)
          validator_for(schema).validate(data).map do |failure|
            failure["error"] || "value at `#{failure["data_pointer"]}` is invalid"
          end
        end

        def valid?(schema, data)
          validator_for(schema).valid?(data)
        end

        private

        def validator_for(schema)
          @validators ||= {}
          @validators[schema.object_id] ||= JSONSchemer.schema(schema)
        end
      end
    end
  end
end
