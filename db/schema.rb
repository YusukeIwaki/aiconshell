# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_09_27_020000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "event_deliveries", force: :cascade do |t|
    t.text "event_id", null: false
    t.jsonb "envelope", default: {}, null: false
    t.text "layer", null: false
    t.text "kind", null: false
    t.bigint "task_id"
    t.text "correlation_id"
    t.timestamptz "occurred_at", null: false
    t.text "teams_channel"
    t.timestamptz "clickhouse_delivered_at"
    t.integer "clickhouse_attempts", default: 0, null: false
    t.timestamptz "clickhouse_next_retry_at"
    t.text "clickhouse_last_error"
    t.timestamptz "clickhouse_skipped_at"
    t.timestamptz "teams_delivered_at"
    t.integer "teams_attempts", default: 0, null: false
    t.timestamptz "teams_next_retry_at"
    t.text "teams_last_error"
    t.timestamptz "teams_skipped_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["clickhouse_delivered_at", "clickhouse_next_retry_at"], name: "index_event_deliveries_on_clickhouse_pending"
    t.index ["event_id"], name: "index_event_deliveries_on_event_id", unique: true
    t.index ["occurred_at"], name: "index_event_deliveries_on_occurred_at"
    t.index ["teams_delivered_at", "teams_next_retry_at"], name: "index_event_deliveries_on_teams_pending"
    t.check_constraint "char_length(kind) <= 128", name: "event_deliveries_kind_length_check"
  end

  create_table "external_events", force: :cascade do |t|
    t.string "plugin", null: false
    t.string "event_id", null: false
    t.string "fingerprint", null: false
    t.string "event_type", default: "message", null: false
    t.string "resource_id", null: false
    t.string "actor_id", default: "", null: false
    t.string "actor_type", default: "human", null: false
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "processed_at"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "task_id"
    t.string "source_fingerprint"
    t.datetime "source_updated_at"
    t.index ["plugin", "event_id", "fingerprint"], name: "index_external_events_on_plugin_event_fingerprint", unique: true
    t.index ["plugin", "resource_id"], name: "index_external_events_on_plugin_resource"
    t.index ["processed_at"], name: "index_external_events_on_processed_at"
    t.index ["task_id"], name: "index_external_events_on_task_id"
  end

  create_table "integration_cursors", force: :cascade do |t|
    t.string "plugin", null: false
    t.string "scope", null: false
    t.jsonb "cursor"
    t.string "lease_token"
    t.datetime "lease_expires_at"
    t.datetime "last_polled_at"
    t.text "last_error"
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["plugin", "scope"], name: "index_integration_cursors_on_plugin_scope", unique: true
  end

  create_table "layer_policies", force: :cascade do |t|
    t.string "layer", null: false
    t.string "provider", null: false
    t.string "model"
    t.string "effort"
    t.text "instructions"
    t.boolean "enabled", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["layer"], name: "index_layer_policies_on_layer", unique: true
  end

  create_table "outbound_actions", force: :cascade do |t|
    t.string "plugin", null: false
    t.string "operation", null: false
    t.jsonb "input", default: {}, null: false
    t.string "idempotency_key", null: false
    t.string "status", default: "pending", null: false
    t.string "external_id"
    t.string "url"
    t.integer "attempts", default: 0, null: false
    t.text "error"
    t.string "error_code"
    t.datetime "last_attempt_at"
    t.bigint "task_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "lease_token"
    t.datetime "lease_expires_at"
    t.datetime "request_started_at"
    t.datetime "next_attempt_at"
    t.string "delivery_batch_key"
    t.index ["delivery_batch_key"], name: "index_outbound_actions_on_delivery_batch_key"
    t.index ["idempotency_key"], name: "index_outbound_actions_on_idempotency_key", unique: true
    t.index ["lease_expires_at"], name: "index_outbound_actions_on_lease_expires_at"
    t.index ["status", "next_attempt_at"], name: "index_outbound_actions_on_status_and_next_attempt_at"
    t.index ["status"], name: "index_outbound_actions_on_status"
    t.index ["task_id"], name: "index_outbound_actions_on_task_id"
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "batch_id"
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "task_feedbacks", force: :cascade do |t|
    t.bigint "task_id", null: false
    t.text "body", null: false
    t.string "author", default: "", null: false
    t.string "author_type", default: "human", null: false
    t.integer "suggested_priority"
    t.datetime "processed_at"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["processed_at"], name: "index_task_feedbacks_on_processed_at"
    t.index ["task_id"], name: "index_task_feedbacks_on_task_id"
    t.check_constraint "author_type::text = 'human'::text", name: "task_feedbacks_human_only"
  end

  create_table "task_requests", force: :cascade do |t|
    t.string "request_id", null: false
    t.string "idempotency_namespace", null: false
    t.string "idempotency_key", null: false
    t.string "title", null: false
    t.text "description", null: false
    t.bigint "external_event_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["external_event_id"], name: "index_task_requests_on_external_event_id", unique: true
    t.index ["idempotency_namespace", "idempotency_key"], name: "index_task_requests_on_namespace_and_key", unique: true
    t.index ["request_id"], name: "index_task_requests_on_request_id", unique: true
  end

  create_table "task_runs", force: :cascade do |t|
    t.bigint "task_id", null: false
    t.string "provider", null: false
    t.string "model"
    t.string "effort"
    t.text "instructions"
    t.string "status", default: "pending", null: false
    t.string "lease_token"
    t.datetime "lease_expires_at"
    t.datetime "heartbeat_at"
    t.jsonb "result"
    t.text "error"
    t.string "error_code"
    t.integer "attempt", default: 1, null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "work_snapshot", default: {}, null: false
    t.index ["lease_token"], name: "index_task_runs_on_lease_token", unique: true
    t.index ["status"], name: "index_task_runs_on_status"
    t.index ["task_id", "status"], name: "index_task_runs_on_task_status"
    t.index ["task_id"], name: "index_task_runs_on_task_id"
    t.index ["task_id"], name: "index_task_runs_one_active_per_task", unique: true, where: "((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('leased'::character varying)::text, ('running'::character varying)::text]))"
    t.check_constraint "attempt > 0", name: "task_runs_positive_attempt"
  end

  create_table "tasks", force: :cascade do |t|
    t.string "title", null: false
    t.text "description", default: "", null: false
    t.string "status", default: "inbox", null: false
    t.integer "priority", default: 0, null: false
    t.string "source_plugin", default: "", null: false
    t.string "source_resource_id", default: "", null: false
    t.datetime "next_action_at"
    t.text "last_error"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "current_run_id"
    t.text "work_plan", default: "", null: false
    t.jsonb "coordination_result"
    t.string "delivery_batch_key"
    t.index ["current_run_id"], name: "index_tasks_on_current_run_id"
    t.index ["next_action_at"], name: "index_tasks_on_next_action_at"
    t.index ["source_plugin", "source_resource_id"], name: "index_tasks_on_source"
    t.index ["source_plugin", "source_resource_id"], name: "index_tasks_one_open_per_source", unique: true, where: "(((source_plugin)::text <> ''::text) AND ((source_resource_id)::text <> ''::text) AND ((status)::text = ANY ((ARRAY['inbox'::character varying, 'ready'::character varying, 'running'::character varying, 'waiting_human'::character varying, 'waiting_review'::character varying, 'waiting_delivery'::character varying, 'failed'::character varying])::text[])))"
    t.index ["status"], name: "index_tasks_on_status"
  end

  add_foreign_key "external_events", "tasks", on_delete: :nullify
  add_foreign_key "outbound_actions", "tasks"
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "task_feedbacks", "tasks"
  add_foreign_key "task_requests", "external_events"
  add_foreign_key "task_runs", "tasks"
  add_foreign_key "tasks", "task_runs", column: "current_run_id", on_delete: :nullify
end
