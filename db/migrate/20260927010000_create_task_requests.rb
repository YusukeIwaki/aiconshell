# frozen_string_literal: true

# Receipt for one accepted admin task request (issue #10). Each row references
# its own ExternalEvent (plugin admin, event_type admin.task_request). The
# public identifier is request_id (opaque UUID); the integer id is never used
# in URLs. Idempotency is enforced in PostgreSQL on the namespace plus key
# pair so UI and API keys never collide.
class CreateTaskRequests < ActiveRecord::Migration[8.0]
  def change
    create_table :task_requests do |t|
      t.string :request_id, null: false
      t.string :idempotency_namespace, null: false
      t.string :idempotency_key, null: false
      t.string :title, null: false
      t.text :description, null: false
      t.references :external_event, null: false, foreign_key: true, index: false
      t.timestamps
    end
    add_index :task_requests, :request_id, unique: true, name: "index_task_requests_on_request_id"
    add_index :task_requests, %i[idempotency_namespace idempotency_key],
              unique: true, name: "index_task_requests_on_namespace_and_key"
    add_index :task_requests, :external_event_id, unique: true, name: "index_task_requests_on_external_event_id"
  end
end
