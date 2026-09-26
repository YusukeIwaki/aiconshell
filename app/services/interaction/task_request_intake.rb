# frozen_string_literal: true

require "securerandom"
require "json_schemer"

module Interaction
  # Shared intake for admin UI and JSON admin API task requests.
  #
  # The input is strict JSON Schema validated title and description only.
  # Unknown fields are rejected. The service persists one receipt row plus one
  # ExternalEvent row in a single transaction with server owned identities:
  # plugin admin, event_type admin.task_request, human actor, and fresh UUID
  # values for request, resource, and event identity. Callers cannot select
  # source metadata.
  #
  # Idempotency is enforced in PostgreSQL on namespace plus key. The same key
  # with the same payload returns the existing receipt; the same key with a
  # different payload is a conflict. UI and API namespaces are independent.
  #
  # This service never creates Coordination owned rows and never contacts
  # workers for immediate work. It only asks for a later triage pass after
  # the receipt is durable; when that ask fails the existing recurring triage
  # still ingests the event. All logs and emitted data stay content free.
  class TaskRequestIntake
    Result = Struct.new(:ok, :code, :receipt, :duplicate, keyword_init: true)

    PLUGIN = "admin"
    EVENT_TYPE = "admin.task_request"
    UI_ACTOR_ID = "admin"
    API_ACTOR_ID = "admin-api"

    INPUT_SCHEMA = {
      "type" => "object",
      "additionalProperties" => false,
      "required" => %w[title description],
      "properties" => {
        "title" => { "type" => "string", "minLength" => 1, "maxLength" => 500 },
        "description" => { "type" => "string", "minLength" => 1, "maxLength" => 8000 }
      }
    }.freeze

    UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    API_KEY_RE = /\A[A-Za-z0-9_\-:.]{1,128}\z/
    NAMESPACES = %w[ui api].freeze

    def initialize(event_sink: WorkflowEvents, clock: Time, triage_job: CoordinationTriageJob)
      @event_sink = event_sink
      @clock = clock
      @triage_job = triage_job
    end

    def call(input, idempotency_key:, namespace:)
      space = namespace.to_s
      return failure(:invalid_namespace) unless NAMESPACES.include?(space)

      key = idempotency_key.is_a?(String) ? idempotency_key : ""
      return failure(:invalid_key) unless valid_key?(space, key)

      normalized = normalize_input(input)
      return failure(:invalid) if normalized.nil?
      # Validate before trimming: String#strip also removes NUL at the ends,
      # but NUL is not valid request content or storable PostgreSQL text.
      return failure(:invalid) if normalized.values.grep(String).any? do |value|
        !value.valid_encoding? || value.include?("\u0000")
      end
      return failure(:invalid) unless JSONSchemer.schema(INPUT_SCHEMA).valid?(normalized)

      title = normalized["title"].to_s.strip
      description = normalized["description"].to_s.strip
      return failure(:invalid) if title.empty? || description.empty?
      existing = TaskRequest.find_by(idempotency_namespace: space, idempotency_key: key)
      if existing
        return same_payload?(existing, title, description) ? success(:duplicate, existing, true) : failure(:conflict)
      end

      receipt = create_receipt(space, key, title, description)
      schedule_after_accept(receipt.request_id)
      success(:accepted, receipt, false)
    rescue ActiveRecord::RecordNotUnique
      # A concurrent insert won the key. Re-read under the unique index and
      # decide duplicate versus conflict. The rolled back attempt leaves no
      # partial rows behind.
      winner = TaskRequest.find_by(idempotency_namespace: space, idempotency_key: key)
      return failure(:conflict) if winner.nil?

      same_payload?(winner, title, description) ? success(:duplicate, winner, true) : failure(:conflict)
    rescue ActiveRecord::RecordInvalid
      failure(:invalid)
    end

    private

    def normalize_input(input)
      return nil unless input.is_a?(Hash)

      input.each_with_object({}) do |(key, value), out|
        out[key.to_s] = value.is_a?(String) ? value.dup.force_encoding(Encoding::UTF_8) : value
      end
    rescue StandardError
      nil
    end

    def valid_key?(space, key)
      return false unless key.is_a?(String)

      if space == "ui"
        key.match?(UUID_RE)
      else
        key.match?(API_KEY_RE)
      end
    end

    def same_payload?(receipt, title, description)
      receipt.title.to_s == title && receipt.description.to_s == description
    end

    def success(code, receipt, duplicate)
      Result.new(ok: true, code: code, receipt: receipt, duplicate: duplicate)
    end

    def failure(code)
      Result.new(ok: false, code: code, receipt: nil, duplicate: false)
    end

    def current_time
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end

    def create_receipt(space, key, title, description)
      attempts = 0
      begin
        attempts += 1
        request_id = SecureRandom.uuid
        event_id = SecureRandom.uuid
        resource_id = SecureRandom.uuid
        now = current_time
        actor_id = space == "api" ? API_ACTOR_ID : UI_ACTOR_ID
        payload = { "title" => title, "description" => description, "request_id" => request_id }
        # Savepoint isolation: a concurrent unique-key race must not abort a
        # caller's outer PostgreSQL transaction before the rescue path queries.
        TaskRequest.transaction(requires_new: true) do
          event = ExternalEvent.create!(
            plugin: PLUGIN, event_id: event_id, fingerprint: event_id,
            event_type: EVENT_TYPE, resource_id: resource_id,
            actor_id: actor_id, actor_type: "human",
            occurred_at: now, payload: payload
          )
          TaskRequest.create!(
            request_id: request_id, idempotency_namespace: space,
            idempotency_key: key, title: title, description: description,
            external_event: event
          )
        end
      rescue ActiveRecord::RecordNotUnique
        # Key races are handled by the caller. A fresh UUID collision is
        # retried with new identities; anything else is re-raised for the
        # caller race path.
        raise unless attempts < 3 && !key_taken?(space, key)

        retry
      end
    end

    def key_taken?(space, key)
      TaskRequest.where(idempotency_namespace: space, idempotency_key: key).exists?
    end

    # Defer triage enqueue and event-sink notification until the outermost
    # transaction commits. On rollback the block never runs, so no enqueue
    # or notification escapes a rolled-back acceptance. With no open
    # transaction the block runs immediately.
    def schedule_after_accept(request_id)
      ActiveRecord.after_all_transactions_commit do
        after_accept_committed(request_id)
      end
    end

    def after_accept_committed(request_id)
      @event_sink.emit(
        layer: "interaction", kind: "task_request.accepted",
        message: "Task request accepted",
        data: { "request_id" => request_id }
      )
      begin
        @triage_job.perform_later
      rescue StandardError => error
        Rails.logger.warn("[task-request] triage ask failed: #{error.class.name}") if defined?(Rails)
        @event_sink.emit(
          layer: "interaction", kind: "task_request.triage_ask_failed",
          message: "Triage ask failed; recurring triage will ingest",
          data: { "request_id" => request_id }
        )
      end
    end
  end
end
