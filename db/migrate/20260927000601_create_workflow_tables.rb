# frozen_string_literal: true

# Workflow tables for issue #6 (Interaction/Coordination/Execution).
# Owned by the workflow lane; the foundation lane owns Solid Queue tables only.
class CreateWorkflowTables < ActiveRecord::Migration[8.0]
  def change
    create_table :external_events do |t|
      t.string :plugin, null: false
      t.string :event_id, null: false
      t.string :fingerprint, null: false
      t.string :event_type, null: false, default: "message"
      t.string :resource_id, null: false
      t.string :actor_id, null: false, default: ""
      t.string :actor_type, null: false, default: "human"
      t.datetime :occurred_at, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :processed_at
      t.text :last_error
      t.timestamps
    end
    add_index :external_events, %i[plugin event_id fingerprint],
              unique: true, name: "index_external_events_on_plugin_event_fingerprint"
    add_index :external_events, %i[plugin resource_id], name: "index_external_events_on_plugin_resource"
    add_index :external_events, :processed_at, name: "index_external_events_on_processed_at"

    create_table :integration_cursors do |t|
      t.string :plugin, null: false
      t.string :scope, null: false
      t.jsonb :cursor
      t.string :lease_token
      t.datetime :lease_expires_at
      t.datetime :last_polled_at
      t.text :last_error
      t.integer :consecutive_failures, null: false, default: 0
      t.timestamps
    end
    add_index :integration_cursors, %i[plugin scope],
              unique: true, name: "index_integration_cursors_on_plugin_scope"

    create_table :tasks do |t|
      t.string :title, null: false
      t.text :description, null: false, default: ""
      t.string :status, null: false, default: "inbox"
      t.integer :priority, null: false, default: 0
      t.string :source_plugin, null: false, default: ""
      t.string :source_resource_id, null: false, default: ""
      t.datetime :next_action_at
      t.text :last_error
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :tasks, :status, name: "index_tasks_on_status"
    add_index :tasks, %i[source_plugin source_resource_id], name: "index_tasks_on_source"
    add_index :tasks, :next_action_at, name: "index_tasks_on_next_action_at"

    create_table :task_feedbacks do |t|
      t.references :task, null: false, foreign_key: true
      t.text :body, null: false
      t.string :author, null: false, default: ""
      t.string :author_type, null: false, default: "human"
      t.integer :suggested_priority
      t.datetime :processed_at
      t.text :last_error
      t.timestamps
    end
    add_index :task_feedbacks, :processed_at, name: "index_task_feedbacks_on_processed_at"

    create_table :task_runs do |t|
      t.references :task, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :model
      t.string :effort
      t.text :instructions
      t.string :status, null: false, default: "pending"
      t.string :lease_token
      t.datetime :lease_expires_at
      t.datetime :heartbeat_at
      t.jsonb :result
      t.text :error
      t.string :error_code
      t.integer :attempt, null: false, default: 1
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :task_runs, :lease_token, unique: true, name: "index_task_runs_on_lease_token"
    add_index :task_runs, %i[task_id status], name: "index_task_runs_on_task_status"
    add_index :task_runs, :status, name: "index_task_runs_on_status"

    create_table :layer_policies do |t|
      t.string :layer, null: false
      t.string :provider, null: false
      t.string :model
      t.string :effort
      t.text :instructions
      t.boolean :enabled, null: false, default: false
      t.timestamps
    end
    add_index :layer_policies, :layer, unique: true, name: "index_layer_policies_on_layer"

    create_table :outbound_actions do |t|
      t.string :plugin, null: false
      t.string :operation, null: false
      t.jsonb :input, null: false, default: {}
      t.string :idempotency_key, null: false
      t.string :status, null: false, default: "pending"
      t.string :external_id
      t.string :url
      t.integer :attempts, null: false, default: 0
      t.text :error
      t.string :error_code
      t.datetime :last_attempt_at
      t.references :task, foreign_key: true
      t.timestamps
    end
    add_index :outbound_actions, :idempotency_key,
              unique: true, name: "index_outbound_actions_on_idempotency_key"
    add_index :outbound_actions, :status, name: "index_outbound_actions_on_status"
  end
end
