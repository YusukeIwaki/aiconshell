# frozen_string_literal: true

module Admin
  # Task board and task detail (read-only except feedback, which has its
  # own controller). This controller never changes task state, priority,
  # or scheduling, and never creates runs or dispatches workers: those
  # decisions belong to Coordination (issue 6).
  class TasksController < BaseController
    STATUSES = %w[inbox ready running waiting_human waiting_review done failed cancelled].freeze
    BOARD_PAGE_SIZE = 50

    def index
      @status = params[:status] if STATUSES.include?(params[:status])
      scope = @status ? Task.where(status: @status) : Task.all
      @total_count = scope.count
      @total_pages = [(@total_count + BOARD_PAGE_SIZE - 1) / BOARD_PAGE_SIZE, 1].max
      raw_page = params[:page]
      requested_page = raw_page.is_a?(String) && raw_page.match?(/\A[1-9]\d{0,8}\z/) ? raw_page.to_i : 1
      @page = [requested_page, @total_pages].min
      tasks = scope.order(priority: :desc, updated_at: :desc, id: :desc)
                   .offset((@page - 1) * BOARD_PAGE_SIZE).limit(BOARD_PAGE_SIZE)
      @columns = (@status ? [@status] : STATUSES).index_with { [] }
      tasks.each do |task|
        key = STATUSES.include?(task.status) ? task.status : "inbox"
        @columns[key] << task
      end
    end

    def show
      @task = Task.find(params[:id])
      @feedbacks = @task.task_feedbacks.order(created_at: :asc)
      @runs = @task.task_runs.order(created_at: :desc, id: :desc).limit(50)
      @outbound_actions = @task.outbound_actions.order(created_at: :desc).limit(50)
      @feedback = @task.task_feedbacks.new
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_tasks_path, alert: "タスクが見つかりませんでした。"
    end
  end
end
