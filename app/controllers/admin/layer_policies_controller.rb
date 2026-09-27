# frozen_string_literal: true

module Admin
  # Layer AI policy editor (operational settings in the DB; secrets stay
  # in ENV/volumes and are never shown here).
  #
  # Any of claude/codex/muse can always be selected and saved, even when
  # the provider CLI/auth is not configured locally: missing setup is
  # shown as a diagnosis badge and fails only at execution time. Unknown
  # provider ids are rejected with a validation-style error.
  class LayerPoliciesController < BaseController
    LAYERS = %w[interaction coordination execution].freeze

    def index
      by_layer = LayerPolicy.where(layer: LAYERS).index_by(&:layer)
      @rows = LAYERS.map do |layer|
        policy = by_layer[layer]
        { layer:, policy:, diagnosis: policy&.provider ? AiStatus.diagnosis(policy.provider, layer: layer) : nil }
      end
    end

    def edit
      @layer = validated_layer
      return redirect_to(admin_layer_policies_path, alert: "不明な層です。") if @layer.nil?

      @policy = LayerPolicy.find_or_initialize_by(layer: @layer)
      @diagnosis = @policy.provider ? AiStatus.diagnosis(@policy.provider, layer: @layer) : nil
    end

    def update
      @layer = validated_layer
      return redirect_to(admin_layer_policies_path, alert: "不明な層です。") if @layer.nil?

      @policy = LayerPolicy.find_or_initialize_by(layer: @layer)
      @policy.assign_attributes(policy_params)
      unless AiStatus.known_provider?(@policy.provider)
        @diagnosis = nil
        flash.now[:alert] = "プロバイダーは claude / codex / muse のいずれかを選んでください。"
        return render(:edit, status: :unprocessable_entity)
      end

      if @policy.save
        redirect_to admin_layer_policies_path, notice: "「#{@layer}」のAIポリシーを保存しました。"
      else
        @diagnosis = AiStatus.diagnosis(@policy.provider, layer: @layer)
        flash.now[:alert] = @policy.errors.full_messages.join(" / ")
        render :edit, status: :unprocessable_entity
      end
    end

    # Saved-policy connection recheck. Uses only the persisted provider and
    # the layer role mapping; extra request params never select the target.
    # Hands a status intent to the ops service and leaves policies and
    # business records untouched. Progress lives on the connections page.
    def connection_check
      @layer = validated_layer
      return redirect_to(admin_layer_policies_path, alert: "不明な層です。") if @layer.nil?

      policy = LayerPolicy.find_by(layer: @layer)
      if policy.nil? || policy.provider.to_s.empty? || !AiStatus.known_provider?(policy.provider)
        return redirect_to(admin_layer_policies_path,
                           alert: "AIポリシーが未設定です。先にproviderを設定してください。")
      end

      role = AiStatus.worker_role_for(@layer)
      if role.nil? || role.empty?
        return redirect_to(admin_layer_policies_path, alert: "不明な層です。")
      end

      existing = AiAuthSession.active.find_by(provider: policy.provider, worker_role: role)
      session = ops.request_status(provider: policy.provider, worker_role: role)
      fresh = existing.nil? || existing.uuid != session.uuid
      redirect_to admin_ai_connections_path, notice: recheck_notice(session, fresh: fresh)
    rescue AiAuth::RequestService::InvalidRequest => e
      redirect_to admin_layer_policies_path, alert: e.message
    end

    private

    def validated_layer
      layer = params[:layer].to_s
      LAYERS.include?(layer) ? layer : nil
    end

    def policy_params
      params.require(:layer_policy).permit(:provider, :model, :effort, :instructions, :enabled)
    end

    def ops
      AiAuth::RequestService.new
    end

    # Fresh means this request created the status session. A reused row
    # (rapid recheck or an in-progress login) must not claim a new accept.
    def recheck_notice(session, fresh:)
      if fresh && session.operation == "status_check"
        "接続状態の再確認を受け付けました。AIアカウント連携画面で進行と結果を確認してください。"
      elsif session.operation == "login"
        "進行中のログインがあります。AIアカウント連携画面で進行と結果を確認してください。"
      else
        "進行中の操作があります。AIアカウント連携画面で進行と結果を確認してください。"
      end
    end
  end
end
