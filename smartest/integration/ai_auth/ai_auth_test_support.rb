# frozen_string_literal: true

# Fake runtime matching the fixed Issue #16 contract. Tests inject this into
# AiAuth::WorkerService; production never uses it (no production stub).
module AiAuthTestSupport
  class FakeAuthRunner
    attr_reader :status_calls, :login_calls

    def initialize(status_results: {}, login_behavior: nil)
      @status_results = status_results
      @login_behavior = login_behavior || ->(*) { { "state" => "connected", "error_code" => nil } }
      @status_calls = []
      @login_calls = []
    end

    def status(provider:)
      @status_calls << { provider: provider.to_s }
      result = @status_results[provider.to_s]
      result = @status_results["*"] if result.nil? && @status_results.key?("*")
      raise result if result.is_a?(Exception)

      result || { "state" => "disconnected", "error_code" => nil }
    end

    def login(provider:, timeout:, on_challenge:, input:, cancelled:)
      @login_calls << { provider: provider.to_s, timeout: timeout }
      @login_behavior.call(provider: provider.to_s, timeout: timeout,
                           on_challenge: on_challenge, input: input, cancelled: cancelled)
    end

    # Immediate success without any challenge.
    def self.immediate(state = "connected", error_code = nil)
      new(login_behavior: ->(*) { { "state" => state, "error_code" => error_code } })
    end

    # Claude-style: one challenge requiring input, then poll input until a
    # code arrives (or cancel). Returns connected once the code is consumed.
    def self.claude_code(challenge: nil, max_polls: 50)
      challenge ||= {
        "verification_uri" => "https://claude.ai/oauth/authorize?code=test-challenge",
        "user_code" => nil,
        "input_required" => true
      }
      new(login_behavior: lambda do |provider:, timeout:, on_challenge:, input:, cancelled:|
        begin
          on_challenge.call(challenge)
        rescue StandardError
          next({ "state" => "failed", "error_code" => "callback_failed" })
        end
        polls = 0
        loop do
          polls += 1
          return { "state" => "cancelled", "error_code" => "cancelled" } if cancelled.call
          return { "state" => "expired", "error_code" => "expired" } if polls > max_polls

          code = nil
          begin
            code = input.call
          rescue StandardError
            next({ "state" => "failed", "error_code" => "callback_failed" })
          end
          break if code.is_a?(String) && !code.empty?

          sleep(0.01)
        end
        { "state" => "connected", "error_code" => nil }
      end)
    end

    # Device approval: challenge without input, then browser approval.
    def self.device_approval(challenge: nil, polls_before_approval: 2)
      challenge ||= {
        "verification_uri" => "https://example.invalid/device/approve-test",
        "user_code" => "ABCD-1234",
        "input_required" => false
      }
      new(login_behavior: lambda do |provider:, timeout:, on_challenge:, input:, cancelled:|
        begin
          on_challenge.call(challenge)
        rescue StandardError
          next({ "state" => "failed", "error_code" => "callback_failed" })
        end
        polls_before_approval.times do
          return { "state" => "cancelled", "error_code" => "cancelled" } if cancelled.call

          sleep(0.01)
        end
        return { "state" => "cancelled", "error_code" => "cancelled" } if cancelled.call

        { "state" => "connected", "error_code" => nil }
      end)
    end

    # Observe cancel and report it.
    def self.cancellable(challenge: nil)
      challenge ||= {
        "verification_uri" => "https://example.invalid/device/cancel-test",
        "user_code" => "WXYZ-9999",
        "input_required" => false
      }
      new(login_behavior: lambda do |provider:, timeout:, on_challenge:, input:, cancelled:|
        begin
          on_challenge.call(challenge)
        rescue StandardError
          next({ "state" => "failed", "error_code" => "callback_failed" })
        end
        100.times do
          return { "state" => "cancelled", "error_code" => "cancelled" } if cancelled.call

          sleep(0.01)
        end
        { "state" => "connected", "error_code" => nil }
      end)
    end
  end

  def with_worker_role(role)
    saved = ENV["AICONSHELL_WORKER_ROLE"]
    ENV["AICONSHELL_WORKER_ROLE"] = role
    yield
  ensure
    ENV["AICONSHELL_WORKER_ROLE"] = saved
  end

  def with_test_runner(runner)
    saved = AiAuthJob.test_runner
    AiAuthJob.test_runner = runner
    yield
  ensure
    AiAuthJob.test_runner = saved
  end
end

include AiAuthTestSupport
