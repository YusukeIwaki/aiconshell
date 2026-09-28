# frozen_string_literal: true

module Admin
  # Integration accounts an AI engineer may use (issue #28): GitHub Apps
  # and Discord. Credentials live in the database and are edited here;
  # values are never rendered back. Basic auth and real CSRF verification
  # stay enabled through BaseController.
  class AccountsController < BaseController
    MAX_KEY_FILE_BYTES = 65_536
    PROVIDERS = %w[github discord].freeze

    def index
      @github = GithubAppsAccount.current
      @discord = DiscordAccount.current
      @api_token = AdminApiToken.current
    end

    def github
      @github = GithubAppsAccount.current
      @github.assign_attributes(github_params)
      if key_upload
        text = read_key_upload(key_upload)
        if text.nil?
          return rerender_index(alert: "秘密鍵ファイルが大きすぎます（上限64KB）。")
        end
        unless GithubAppsAccount.valid_private_key?(text)
          return rerender_index(alert: "秘密鍵ファイルがRSA秘密鍵として読み取れませんでした。")
        end
        @github.private_key = text
      end
      if @github.save
        redirect_to admin_accounts_path, notice: "GitHub Apps アカウントを保存しました。"
      else
        rerender_index(alert: "保存できませんでした（#{@github.errors.full_messages.first}）。")
      end
    end

    def discord
      @discord = DiscordAccount.current
      token = discord_params[:bot_token].to_s
      # Blank input keeps the stored token; clearing is done by saving an
      # explicitly empty value through the clear checkbox.
      if discord_params[:clear_token] == "1"
        @discord.bot_token = nil
      elsif token.present?
        @discord.bot_token = token
      end
      if @discord.save
        redirect_to admin_accounts_path, notice: "Discord アカウントを保存しました。"
      else
        rerender_index(alert: "保存できませんでした（#{@discord.errors.full_messages.first}）。")
      end
    end

    def health_check
      provider = params[:provider].to_s
      unless PROVIDERS.include?(provider)
        return redirect_to admin_accounts_path, alert: "不明なアカウントです。"
      end
      result = Accounts::HealthCheck.call(plugin: provider)
      if result.ok?
        redirect_to admin_accounts_path, notice: "#{provider_name(provider)}の接続確認が正常に完了しました。"
      else
        redirect_to admin_accounts_path, alert: "#{provider_name(provider)}の接続確認に失敗しました（#{health_error_label(result.code)}）。"
      end
    end

    def rotate_api_token
      _record, plaintext = AdminApiToken.rotate!
      flash[:shown_api_token] = plaintext
      redirect_to admin_accounts_path, notice: "管理APIキーを再発行しました。下に表示される値を控えてください（再表示されません）。"
    end

    private

    def rerender_index(alert:)
      @discord ||= DiscordAccount.current
      @github ||= GithubAppsAccount.current
      @api_token = AdminApiToken.current
      flash.now[:alert] = alert
      render :index, status: :unprocessable_entity
    end

    def github_params
      params.fetch(:github_apps_account, {}).permit(:app_id, :installation_id, :api_url)
    end

    def key_upload
      params.dig(:github_apps_account, :private_key_file)
    end

    def read_key_upload(upload)
      return nil unless upload.respond_to?(:read)

      upload.rewind if upload.respond_to?(:rewind)
      text = upload.read(MAX_KEY_FILE_BYTES + 1).to_s
      return nil if text.bytesize > MAX_KEY_FILE_BYTES

      text
    rescue StandardError
      nil
    end

    def discord_params
      params.fetch(:discord_account, {}).permit(:bot_token, :clear_token)
    end

    def provider_name(provider)
      provider == "github" ? "GitHub Apps" : "Discord"
    end

    def health_error_label(code)
      {
        credentials_missing: "認証情報が未設定です",
        missing_permissions: "必要な権限が不足しています",
        unauthorized: "認証が拒否されました",
        rate_limited: "レート制限中です",
        upstream_error: "外部サービスへの接続に失敗しました"
      }.fetch(code.to_sym, "確認中にエラーが発生しました")
    end
  end
end
