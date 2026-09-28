# frozen_string_literal: true

require "db_helper"
require "base64"
require "nokogiri"
require "uri"
require_relative "request_acceptance_helper"

module RequestAcceptance
  # Small request/scenario conveniences. All application objects remain real.
  module Workflow
    module_function

    def api_headers
      {
        "HTTP_HOST" => "app.test",
        "CONTENT_TYPE" => "application/json",
        "HTTP_AUTHORIZATION" => "Bearer #{ENV.fetch('ADMIN_API_TOKEN')}"
      }
    end

    def api_post(http, payload, key:)
      http.post("/api/admin/task_requests", JSON.generate(payload),
                api_headers.merge("HTTP_IDEMPOTENCY_KEY" => key))
      JSON.parse(http.last_response.body)
    end

    def api_get(http, request_id)
      http.get("/api/admin/task_requests/#{request_id}", {}, api_headers)
      JSON.parse(http.last_response.body)
    end

    def submit(http, key: "fixture-request", title: "Open issue review",
               description: "Review o/r open issues and notify the configured Discord channel if urgent.")
      body = api_post(http, { title: title, description: description }, key: key)
      raise "request fixture expected HTTP 202" unless http.last_response.status == 202

      TaskRequest.find_by!(request_id: body.fetch("request_id"))
    end

    def configure_policy(provider: "claude")
      LayerPolicy.create!(layer: "coordination", provider: provider, model: "fixture-model",
                          effort: "max", instructions: "Synthetic fixture policy", enabled: true)
    end

    def triage(ctx)
      Coordination::TriageService.new(ai_runner: ctx.runner, registry: ctx.registry, clock: ctx.clock)
    end

    def prompt_data(call, key)
      prefix = "#{key}: "
      line = call.fetch(:stdin_data).lines.find { |candidate| candidate.start_with?(prefix) }
      raise "missing documented #{key} prompt data" unless line

      JSON.parse(line.delete_prefix(prefix))
    end

    def task_id(call)
      prompt_data(call, "TASKS").fetch(0).fetch("task_id")
    end

    def read_answer(call)
      {
        "read_requests" => [{
          "task_id" => task_id(call), "plugin" => "github", "operation" => "list_issues",
          "input" => { "scope" => "o/r" }
        }]
      }
    end

    def discord_action(body, scope: DISCORD_WRITE_TARGET)
      {
        "plugin" => "discord", "operation" => "send_message",
        "input" => { "scope" => scope, "body" => body }
      }
    end

    def result_answer(call, summary:, actions: [], priority: 10)
      {
        "rulings" => [{
          "task_id" => task_id(call), "priority" => priority,
          "result" => { "summary" => summary, "actions" => actions }
        }]
      }
    end

    def admin_headers
      credentials = "#{ENV.fetch('ADMIN_USERNAME')}:#{ENV.fetch('ADMIN_PASSWORD')}"
      {
        "HTTP_HOST" => "app.test",
        "HTTP_AUTHORIZATION" => "Basic #{Base64.strict_encode64(credentials)}",
        "HTTP_USER_AGENT" => "Mozilla/5.0 Chrome/131.0.0.0 Safari/537.36"
      }
    end

    def event_text
      JSON.generate(EventDelivery.order(:id).pluck(:envelope))
    end
  end
end
