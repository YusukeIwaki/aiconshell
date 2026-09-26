# frozen_string_literal: true

# Issue #11 (pass 2): persistent admin coordination-result batches.
# Tasks carry the stored result summary/count plus the active delivery batch
# key; every OutboundAction in the batch carries the same key. The
# one-open-task-per-source partial index must treat waiting_delivery as open.
class Issue11DeliveryBatches < ActiveRecord::Migration[8.0]
  OPEN_WITHOUT_DELIVERY = "source_plugin <> '' AND source_resource_id <> '' AND " \
    "status IN ('inbox', 'ready', 'running', 'waiting_human', 'waiting_review', 'failed')".freeze
  OPEN_WITH_DELIVERY = "source_plugin <> '' AND source_resource_id <> '' AND " \
    "status IN ('inbox', 'ready', 'running', 'waiting_human', 'waiting_review', 'waiting_delivery', 'failed')".freeze

  def up
    add_column :tasks, :coordination_result, :jsonb
    add_column :tasks, :delivery_batch_key, :string
    add_column :outbound_actions, :delivery_batch_key, :string
    add_index :outbound_actions, :delivery_batch_key, name: "index_outbound_actions_on_delivery_batch_key"
    remove_index :tasks, name: "index_tasks_one_open_per_source"
    add_index :tasks, %i[source_plugin source_resource_id], unique: true,
              where: OPEN_WITH_DELIVERY, name: "index_tasks_one_open_per_source"
  end

  def down
    remove_index :tasks, name: "index_tasks_one_open_per_source"
    add_index :tasks, %i[source_plugin source_resource_id], unique: true,
              where: OPEN_WITHOUT_DELIVERY, name: "index_tasks_one_open_per_source"
    remove_index :outbound_actions, name: "index_outbound_actions_on_delivery_batch_key"
    remove_column :outbound_actions, :delivery_batch_key
    remove_column :tasks, :delivery_batch_key
    remove_column :tasks, :coordination_result
  end
end
