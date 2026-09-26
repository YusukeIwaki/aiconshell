# frozen_string_literal: true

module Admin
  # Human-only feedback intake. A feedback row is information *for*
  # Coordination: it never updates task state/priority/scheduling
  # directly and never creates runs or dispatches workers.
  #
  # Strong parameters accept body/author only; author_type is always
  # forced to "human". Any status, priority, suggested priority, or run
  # payload smuggled into the request is ignored.
  class FeedbacksController < BaseController
    def create
      task = Task.find(params[:task_id])
      feedback = task.task_feedbacks.build(feedback_params.merge(author_type: "human"))
      if feedback.save
        redirect_to admin_task_path(task), notice: "フィードバックを保存しました。整理層が取り込みます。"
      else
        redirect_to admin_task_path(task), alert: feedback.errors.full_messages.join(" / ")
      end
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_tasks_path, alert: "タスクが見つかりませんでした。"
    end

    private

    def feedback_params
      params.require(:task_feedback).permit(:body, :author)
    end
  end
end
