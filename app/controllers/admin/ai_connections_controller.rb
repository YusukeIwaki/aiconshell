# frozen_string_literal: true

module Admin
  # AI account linkage per provider and worker role. Hands operator intent to
  # the ops request service, which persists the session and reserves the
  # role queue. Never touches business tasks directly.
  class AiConnectionsController < BaseController
    before_action :set_private_headers

    def index
      ops.recover_expired!
      snapshots = AiConnection.where(
        provider: AiConnection::PROVIDERS, worker_role: AiConnection::WORKER_ROLES
      ).index_by { |row| [row.provider, row.worker_role] }
      actives = AiAuthSession.active.where(
        provider: AiConnection::PROVIDERS, worker_role: AiConnection::WORKER_ROLES
      ).index_by { |row| [row.provider, row.worker_role] }
      @rows = AiConnection::PROVIDERS.product(AiConnection::WORKER_ROLES).map do |provider, role|
        session = actives[[provider, role]]
        {
          provider: provider,
          worker_role: role,
          snapshot: snapshots[[provider, role]],
          session: session,
          challenge: session&.challenge
        }
      end
      @has_active = actives.any?
    end

    def login
      session = ops.request_login(provider: params[:provider], worker_role: params[:worker_role])
      redirect_to admin_ai_connections_path, notice: start_notice(session)
    rescue AiAuth::RequestService::InvalidRequest => e
      redirect_to admin_ai_connections_path, alert: e.message
    end

    def status_check
      session = ops.request_status(provider: params[:provider], worker_role: params[:worker_role])
      redirect_to admin_ai_connections_path, notice: check_notice(session)
    rescue AiAuth::RequestService::InvalidRequest => e
      redirect_to admin_ai_connections_path, alert: e.message
    end

    def code
      ops.submit_code(session_uuid: params[:id], code: params[:auth_code])
      redirect_to admin_ai_connections_path, notice: "認証コードを受け付けました。workerが処理を続けます。"
    rescue AiAuth::RequestService::InvalidRequest => e
      redirect_to admin_ai_connections_path, alert: e.message
    end

    def cancel
      ops.cancel(session_uuid: params[:id])
      redirect_to admin_ai_connections_path, notice: "キャンセルを受け付けました。"
    rescue AiAuth::RequestService::InvalidRequest => e
      redirect_to admin_ai_connections_path, alert: e.message
    end

    private

    def ops
      AiAuth::RequestService.new
    end

    def set_private_headers
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
    end

    def start_notice(session)
      if session.status == "queued" && session.created_at && session.created_at > 10.seconds.ago
        "連携開始を受け付けました。案内に従って認証してください。"
      else
        "進行中の操作があります。案内に従って認証してください。"
      end
    end

    def check_notice(session)
      if session.status == "queued" && session.created_at && session.created_at > 10.seconds.ago
        "状態確認を受け付けました。workerの確認結果をお待ちください。"
      else
        "進行中の操作があります。結果をお待ちください。"
      end
    end
  end
end
