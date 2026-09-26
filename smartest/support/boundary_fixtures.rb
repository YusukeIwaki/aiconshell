# frozen_string_literal: true

require "json"
require_relative "../../lib/aiconshell/plugins/errors"
require_relative "../../lib/aiconshell/plugins/http"

# Strict boundary fixtures for request-acceptance tests (issue #12).
#
# HttpTransport replaces the HTTP boundary only: every request must match a
# scripted expectation, each reply is consumed by exactly one call, and all
# requests are recorded as immutable snapshots. Error mapping uses the real
# Http.raise_for_status!, so typed errors behave like the production
# transport. No network, monkeypatches, global state, or Smartest
# assertions: failures raise ExpectationError for the test to assert.
module BoundaryFixtures
  class ExpectationError < StandardError; end

  class HttpTransport
    Expectation = Struct.new(:method, :pattern, :reply, :consumed) do
      def matches?(http_method, url)
        return false unless method == http_method

        case pattern
        when Regexp then pattern.match?(url)
        else pattern.to_s == url
        end
      end
    end

    def initialize(clock: Time)
      @clock = clock
      @expectations = []
      @requests = []
      @unexpected = []
    end

    # Script one single-use JSON reply for method + exact URL or Regexp.
    def expect_json(method, url_or_pattern, status: 200, body: {}, headers: {})
      response = Aiconshell::Plugins::Http::Response.new(
        status: status, headers: headers, body: JSON.generate(body)
      )
      expect_response(method, url_or_pattern, response)
    end

    # Script one single-use prebuilt real Http::Response.
    def expect_response(method, url_or_pattern, response)
      unless response.is_a?(Aiconshell::Plugins::Http::Response)
        raise ArgumentError, "expect_response needs an Http::Response"
      end

      @expectations << Expectation.new(method.to_s.upcase, url_or_pattern,
                                       [:response, response], false)
      self
    end

    # Script one single-use boundary failure (e.g. TransportTimeout).
    def expect_error(method, url_or_pattern, error)
      raise ArgumentError, "expect_error needs a StandardError" unless error.is_a?(StandardError)

      @expectations << Expectation.new(method.to_s.upcase, url_or_pattern,
                                       [:error, error], false)
      self
    end

    # First unconsumed method+URL match answers: endpoints stay independent
    # (no global order) while same-endpoint replies keep registration order.
    def request(method:, url:, headers: {}, body: nil)
      http_method = snapshot(method.to_s.upcase)
      entry = {
        method: http_method,
        url: snapshot(url.to_s),
        headers: snapshot((headers || {}).to_h),
        body: snapshot(body)
      }.freeze
      @requests << entry

      expectation = @expectations.find do |candidate|
        !candidate.consumed && candidate.matches?(http_method, entry[:url])
      end
      unless expectation
        @unexpected << entry
        raise ExpectationError, unexpected_message(http_method, url)
      end

      expectation.consumed = true
      kind, payload = expectation.reply
      raise payload if kind == :error

      Aiconshell::Plugins::Http.raise_for_status!(method, url, payload, clock: @clock)
      payload
    end

    def requests
      @requests.dup
    end

    def unexpected_requests
      @unexpected.dup
    end

    def requests_to(url_or_pattern, method: nil)
      normalized = method.nil? ? nil : method.to_s.upcase
      @requests.select do |entry|
        next false if normalized && entry[:method] != normalized

        case url_or_pattern
        when Regexp then url_or_pattern.match?(entry[:url])
        else entry[:url] == url_or_pattern.to_s
        end
      end
    end

    # Fails on unexpected calls (even rescued ones) and unconsumed scripts.
    def assert_consumed!
      pending = @expectations.reject(&:consumed)
      return true if @unexpected.empty? && pending.empty?

      raise ExpectationError, unconsumed_message(pending)
    end

    private

    # Failure messages carry counts plus sanitized URLs only; never headers/bodies.
    def unexpected_message(http_method, url)
      "unexpected HTTP request ##{@requests.size}: #{http_method} " \
        "#{Aiconshell::Plugins::Http.sanitize_url(url)} " \
        "(no matching expectation; #{@expectations.reject(&:consumed).size} expectation(s) pending)"
    end

    def unconsumed_message(pending)
      parts = []
      parts << "#{@unexpected.size} unexpected call(s)" unless @unexpected.empty?
      unless pending.empty?
        details = pending.first(5).map { |item| describe(item) }.join("; ")
        parts << "#{pending.size} unconsumed expectation(s): #{details}"
      end
      "boundary expectations not satisfied: #{parts.join(", ")}"
    end

    def describe(expectation)
      pattern = expectation.pattern
      shown = pattern.is_a?(Regexp) ? "<regexp>" : Aiconshell::Plugins::Http.sanitize_url(pattern)
      "#{expectation.method} #{shown}"
    end

    # Deep dup + freeze: caller mutation cannot rewrite evidence, and caller-owned objects stay unfrozen.
    def snapshot(value)
      case value
      when Hash
        value.to_h.each_with_object({}) do |(key, val), duped|
          duped[snapshot(key)] = snapshot(val)
        end.freeze
      when Array
        value.map { |element| snapshot(element) }.freeze
      when String
        value.dup.freeze
      when Symbol, Numeric, true, false, nil
        value
      else
        begin
          value.dup.freeze
        rescue TypeError
          value
        end
      end
    end
  end
end
