# frozen_string_literal: true

module Admin
  # EventLog search (read-only). All user input is validated before the
  # search backend is touched: layer allowlist, bounded text, integer
  # task id, strict time parsing, clamped limit. There are intentionally
  # no sort/order parameters; results always arrive newest-first from the
  # backend. Backend outages (ClickHouse down, search unconfigured, query
  # failures) render an inline status banner, never a 500.
  class EventLogsController < BaseController
    LAYERS = %w[interaction coordination execution].freeze
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 200
    MAX_QUERY_LENGTH = 500
    MAX_FIELD_LENGTH = 200
    KIND_PATTERN = /\A[a-zA-Z0-9_.\-:]+\z/

    def index
      @form = search_form_params
      @events = []
      @search_error = nil

      return if @form[:submitted] == false

      validation_error = validate_form!(@form)
      if validation_error
        @search_error = validation_error
        return
      end

      @events = EventLogSearch.search(
        query: presence(@form[:query]),
        layer: presence(@form[:layer]),
        kind: presence(@form[:kind]),
        task_id: @form[:task_id],
        correlation_id: presence(@form[:correlation_id]),
        since: @form[:since],
        until_time: @form[:until_time],
        limit: @form[:limit]
      )
    rescue EventLogSearch::NotConfigured
      @search_error = "EventLog検索はまだ設定されていません（検索バックエンド未接続）。他の管理ページは利用できます。"
    rescue StandardError
      @search_error = "EventLog検索でエラーが発生しました。時間をおいて再試行してください。（他ページへの影響はありません）"
    end

    private

    def search_form_params
      container = params[:search]
      container = nil unless container.is_a?(ActionController::Parameters)
      raw = (container || ActionController::Parameters.new({})).permit(
        :query, :layer, :kind, :task_id, :correlation_id, :since, :until, :limit
      ).to_h
      {
        submitted: params.key?(:search),
        query: raw["query"].to_s.strip,
        layer: raw["layer"].to_s.strip,
        kind: raw["kind"].to_s.strip,
        task_id: raw["task_id"].to_s.strip,
        correlation_id: raw["correlation_id"].to_s.strip,
        since: raw["since"].to_s.strip,
        until_time: raw["until"].to_s.strip,
        limit: raw["limit"].to_s.strip
      }
    end

    # Normalizes types in place; returns a Japanese error message, or nil.
    def validate_form!(form)
      if form[:query].length > MAX_QUERY_LENGTH
        return "検索キーワードは#{MAX_QUERY_LENGTH}文字以内で入力してください。"
      end
      if form[:layer].present? && !LAYERS.include?(form[:layer])
        return "層の指定が正しくありません。"
      end
      if form[:kind].present? &&
          (form[:kind].length > MAX_FIELD_LENGTH || form[:kind] !~ KIND_PATTERN)
        return "種別は英数字・._-: の#{MAX_FIELD_LENGTH}文字以内で入力してください。"
      end
      if form[:correlation_id].length > MAX_FIELD_LENGTH
        return "相関IDは#{MAX_FIELD_LENGTH}文字以内で入力してください。"
      end

      task_error = normalize_task_id!(form)
      return task_error if task_error

      time_error = normalize_times!(form)
      return time_error if time_error

      form[:limit] = normalize_limit(form[:limit])
      nil
    end

    def normalize_task_id!(form)
      return nil if form[:task_id].blank?

      unless form[:task_id] =~ /\A\d{1,10}\z/
        form[:task_id] = nil
        return "タスクIDは数値で入力してください。"
      end
      form[:task_id] = form[:task_id].to_i
      nil
    end

    def normalize_times!(form)
      %i[since until_time].each do |key|
        next if form[key].blank?

        begin
          form[key] = Time.iso8601(form[key]).utc.iso8601
        rescue ArgumentError
          form[key] = nil
          return "日時の形式が正しくありません（ISO8601で入力してください）。"
        end
      end
      nil
    end

    def normalize_limit(raw)
      limit = raw.to_s =~ /\A\d+\z/ ? raw.to_i : DEFAULT_LIMIT
      limit = DEFAULT_LIMIT if limit <= 0
      [limit, MAX_LIMIT].min
    end

    def presence(value)
      value.to_s.strip.then { |stripped| stripped.empty? ? nil : stripped }
    end
  end
end
