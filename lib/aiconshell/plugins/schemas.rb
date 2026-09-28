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

      # health_check input: {} (no scope; account-wide connectivity check).
      HEALTH_CHECK_INPUT = {
        "type" => "object",
        "properties" => {},
        "additionalProperties" => false
      }.freeze

      # health_check output: {"ok": bool, ...}. "missing" lists ungranted
      # "<permission>:<level>" entries (GitHub); "bot_id" identifies the
      # authenticated bot (Discord). Both are optional per plugin.
      HEALTH_CHECK_OUTPUT = {
        "type" => "object",
        "required" => %w[ok],
        "properties" => {
          "ok" => { "type" => "boolean" },
          "missing" => { "type" => "array", "items" => { "type" => "string" } },
          "bot_id" => { "type" => "string" }
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

      LIST_ISSUES_SCOPE = {
        "type" => "string", "maxLength" => 256,
        "pattern" => '\\A[A-Za-z0-9_-]+/(?!\\.{1,2}\\z)[A-Za-z0-9_.-]+\\z'
      }.freeze
      LIST_ISSUES_CURSOR = {
        "type" => "object",
        "required" => %w[version scope page],
        "properties" => {
          "version" => { "type" => "integer", "enum" => [1] },
          "scope" => LIST_ISSUES_SCOPE,
          "page" => { "type" => "integer", "minimum" => 2, "maximum" => 100 }
        },
        "additionalProperties" => false
      }.freeze

      # The pure operation preflight additionally binds cursor.scope to scope.
      LIST_ISSUES_INPUT = {
        "type" => "object",
        "required" => %w[scope],
        "properties" => {
          "scope" => LIST_ISSUES_SCOPE,
          "cursor" => { "anyOf" => [{ "type" => "null" }, { "type" => "object", "maxProperties" => 0 }, LIST_ISSUES_CURSOR] }
        },
        "additionalProperties" => false
      }.freeze

      # Normalized open issue. Long fields are truncated with explicit flags;
      # nothing is silently dropped.
      LIST_ISSUE = {
        "type" => "object",
        "required" => %w[id number title title_truncated body body_truncated
                          labels labels_truncated state url url_truncated],
        "properties" => {
          "id" => { "type" => "integer", "minimum" => 1, "maximum" => 9223372036854775807 },
          "number" => { "type" => "integer", "minimum" => 1, "maximum" => 2147483647 },
          "title" => { "type" => "string", "maxLength" => 300 },
          "title_truncated" => { "type" => "boolean" },
          "body" => { "type" => "string", "maxLength" => 2000 },
          "body_truncated" => { "type" => "boolean" },
          "labels" => { "type" => "array", "maxItems" => 10,
                        "items" => { "type" => "string", "maxLength" => 100 } },
          "labels_truncated" => { "type" => "boolean" },
          "state" => { "type" => "string", "enum" => %w[open] },
          "url" => { "type" => %w[string null], "maxLength" => 512 },
          "url_truncated" => { "type" => "boolean" }
        },
        "additionalProperties" => false
      }.freeze

      # list_issues output: {"issues": [...], "complete": bool,
      # "next_cursor": object|null, "truncated": bool, "limit_reached": bool}.
      # Page 100 can be incomplete with no usable continuation.
      LIST_ISSUES_OUTPUT = {
        "type" => "object",
        "required" => %w[issues complete next_cursor truncated limit_reached],
        "properties" => {
          "issues" => { "type" => "array", "maxItems" => 30, "items" => LIST_ISSUE },
          "complete" => { "type" => "boolean" },
          "next_cursor" => { "anyOf" => [{ "type" => "null" }, LIST_ISSUES_CURSOR] },
          "truncated" => { "type" => "boolean" },
          "limit_reached" => { "type" => "boolean" }
        },
        "additionalProperties" => false,
        "oneOf" => [
          { "properties" => { "complete" => { "const" => true }, "next_cursor" => { "type" => "null" }, "limit_reached" => { "const" => false } } },
          { "properties" => { "complete" => { "const" => false }, "next_cursor" => LIST_ISSUES_CURSOR, "limit_reached" => { "const" => false } } },
          { "properties" => { "complete" => { "const" => false }, "next_cursor" => { "type" => "null" }, "limit_reached" => { "const" => true } } }
        ]
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
