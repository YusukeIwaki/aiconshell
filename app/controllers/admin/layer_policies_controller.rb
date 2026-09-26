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
        { layer:, policy:, diagnosis: policy&.provider ? AiStatus.diagnosis(policy.provider) : nil }
      end
    end

    def edit
      @layer = validated_layer
      return redirect_to(admin_layer_policies_path, alert: "不明な層です。") if @layer.nil?

      @policy = LayerPolicy.find_or_initialize_by(layer: @layer)
      @diagnosis = @policy.provider ? AiStatus.diagnosis(@policy.provider) : nil
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
        @diagnosis = AiStatus.diagnosis(@policy.provider)
        flash.now[:alert] = @policy.errors.full_messages.join(" / ")
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def validated_layer
      layer = params[:layer].to_s
      LAYERS.include?(layer) ? layer : nil
    end

    def policy_params
      params.require(:layer_policy).permit(:provider, :model, :effort, :instructions, :enabled)
    end
  end
end
