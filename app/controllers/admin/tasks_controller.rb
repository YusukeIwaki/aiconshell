# frozen_string_literal: true

module Admin
  # Task board and task detail (read-only except feedback, which has its
  # own controller). This controller never changes task state, priority,
  # or scheduling, and never creates runs or dispatches workers: those
  # decisions belong to Coordination (issue 6).
  class TasksController < BaseController
    STATUSES = %w[inbox ready running waiting_human waiting_review done failed cancelled].freeze
    BOARD_LIMIT = 200

    def index
      tasks = Task.order(priority: :desc, updated_at: :desc).limit(BOARD_LIMIT)
      @columns = STATUSES.index_with { [] }
      tasks.each do |task|
        key = STATUSES.include?(task.status) ? task.status : "inbox"
        @columns[key] << task
      end
    end

    def show
      @task = Task.find(params[:id])
      @feedbacks = @task.task_feedbacks.order(created_at: :asc)
      @runs = @task.task_runs.order(created_at: :desc).limit(50)
      @outbound_actions = @task.outbound_actions.order(created_at: :desc).limit(50)
      @feedback = @task.task_feedbacks.new
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_tasks_path, alert: "タスクが見つかりませんでした。"
    end
  end
end
