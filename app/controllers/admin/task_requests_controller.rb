# frozen_string_literal: true

require "securerandom"

module Admin
  # Human task request intake form and durable receipt.
  #
  # This controller only accepts operator input and shows receipts. It never
  # changes Coordination owned rows and never asks workers for immediate
  # work; the shared intake service owns persistence and follow-up.
  class TaskRequestsController < BaseController
    # Top-level form envelope plus Rails routing/form control fields. Any
    # other top-level input (plugin/source/status/priority/provider/worker/
    # commands/event metadata included) is rejected.
    TOP_LEVEL_ALLOWED = %w[
      task_request idempotency_key authenticity_token commit
      controller action format
    ].freeze

    def new
      @idempotency_key = SecureRandom.uuid
      @title = ""
      @description = ""
    end

    def create
      key_param = params[:idempotency_key]
      key = key_param.is_a?(String) ? key_param : ""
      raw = params[:task_request]

      title_value = raw.is_a?(ActionController::Parameters) ? raw[:title] : nil
      description_value = raw.is_a?(ActionController::Parameters) ? raw[:description] : nil
      title_text = title_value.is_a?(String) ? title_value : ""
      description_text = description_value.is_a?(String) ? description_value : ""

      top_extra = params.keys.map(&:to_s) - TOP_LEVEL_ALLOWED
      unless top_extra.empty?
        fallback = key.presence || SecureRandom.uuid
        return render_new("使用できない入力項目が含まれています。",
          title_text, description_text, fallback, :unprocessable_entity)
      end

      unless raw.is_a?(ActionController::Parameters)
        return render_new("タイトルと内容を入力してください。", "", "", SecureRandom.uuid, :unprocessable_entity)
      end

      extra = raw.keys.map(&:to_s) - %w[title description]
      unless extra.empty?
        fallback = key.presence || SecureRandom.uuid
        return render_new("使用できない入力項目が含まれています。",
          title_text, description_text, fallback, :unprocessable_entity)
      end

      result = Interaction::TaskRequestIntake.new.call(
        { "title" => title_value, "description" => description_value },
        idempotency_key: key, namespace: "ui"
      )
      if result.ok
        redirect_to admin_task_request_path(result.receipt), notice: "依頼を受け付けました。"
      elsif result.code == :conflict
        render_new("このフォームは別の内容で送信済みです。新しい内容は新しい依頼として作成してください。",
          title_text, description_text, key, :conflict)
      elsif result.code == :invalid_key
        render_new("送信情報が無効なため、新しいフォームでお試しください。",
          title_text, description_text, SecureRandom.uuid, :unprocessable_entity)
      else
        fallback = key.presence || SecureRandom.uuid
        render_new("タイトル（1〜500文字）と内容（1〜8000文字）を入力してください。",
          title_text, description_text, fallback, :unprocessable_entity)
      end
    end

    def show
      receipt = TaskRequest.find_by(request_id: params[:id].to_s)
      return redirect_to new_admin_task_request_path, alert: "受付が見つかりませんでした。" if receipt.nil?

      @receipt = receipt
      @event = receipt.external_event
    end

    private

    def render_new(message, title, description, key, status)
      @title = title
      @description = description
      @idempotency_key = key
      flash.now[:alert] = message
      render :new, status: status
    end
  end
end
