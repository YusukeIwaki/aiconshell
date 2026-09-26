# frozen_string_literal: true

class FenceWorkflowRuns < ActiveRecord::Migration[8.0]
  def change
    add_reference :tasks, :current_run, foreign_key: { to_table: :task_runs, on_delete: :nullify }
    add_column :tasks, :work_plan, :text, null: false, default: ""
    add_column :task_runs, :work_snapshot, :jsonb, null: false, default: {}
    add_reference :external_events, :task, foreign_key: { on_delete: :nullify }

    add_index :task_runs, :task_id, unique: true,
              where: "status IN ('pending', 'leased', 'running')", name: "index_task_runs_one_active_per_task"
    add_index :tasks, %i[source_plugin source_resource_id], unique: true,
              where: "source_plugin <> '' AND source_resource_id <> '' AND status IN ('inbox', 'ready', 'running', 'waiting_human', 'waiting_review', 'failed')",
              name: "index_tasks_one_open_per_source"
    add_check_constraint :task_runs, "attempt > 0", name: "task_runs_positive_attempt"
    add_check_constraint :task_feedbacks, "author_type = 'human'", name: "task_feedbacks_human_only"
  end
end
