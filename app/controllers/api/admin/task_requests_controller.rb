# frozen_string_literal: true

require "json"

module Api
  module Admin
    # JSON intake for admin task requests. Accepts JSON bodies only and
    # delegates persistence to the shared intake service. Reads are plain
    # receipt lookups by opaque request id.
    class TaskRequestsController < BaseController
      def create
        return render_json_only unless json_content_type?

        body = parse_body
        return render_json_only if body == :json_only
        return render_malformed if body == :malformed
        # The body byte limit applies in addition to the character limits,
        # including any JSON formatting whitespace.
        return render_invalid if body == :oversized
        return render_invalid unless body.is_a?(Hash)

        key = request.headers["Idempotency-Key"]
        key = key.is_a?(String) ? key : ""
        result = Interaction::TaskRequestIntake.new.call(
          body, idempotency_key: key, namespace: "api"
        )
        if result.ok
          receipt = result.receipt
          response.set_header("Location", api_admin_task_request_path(receipt))
          render json: receipt_json(receipt), status: :accepted
        elsif result.code == :conflict
          render json: { error: "idempotency_conflict" }, status: :conflict
        elsif result.code == :invalid_key
          render json: { error: "invalid_idempotency_key" }, status: :unprocessable_entity
        else
          render_invalid
        end
      end

      def show
        receipt = TaskRequest.find_by(request_id: params[:id].to_s)
        return render json: { error: "not_found" }, status: :not_found if receipt.nil?

        render json: receipt_json(receipt), status: :ok
      end

      private

      # Empty or unparseable Content-Type is wrong input, not a 406: reject
      # it as json_only like any other non-JSON media type.
      def json_content_type?
        request.media_type == "application/json"
      rescue ActionDispatch::Http::MimeNegotiation::InvalidType
        false
      end

      def parse_body
        guard = request.env[ApiTaskRequestBodyGuard::ENV_KEY]
        if guard.is_a?(Hash)
          case guard[:status]
          when :ok then return guard[:data]
          when :oversized then return :oversized
          when :json_only then return :json_only
          else return :malformed
          end
        end

        raw = request.raw_post.to_s
        return :malformed if raw.strip.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        :malformed
      end

      def render_json_only
        render json: { error: "json_only" }, status: :bad_request
      end

      def render_malformed
        render json: { error: "malformed_json" }, status: :bad_request
      end

      def render_invalid
        render json: { error: "invalid_payload" }, status: :unprocessable_entity
      end

      def receipt_json(receipt)
        receipt = receipt.reload
        {
          request_id: receipt.request_id,
          status: receipt.status,
          task_id: receipt.task_id
        }
      end
    end
  end
end
