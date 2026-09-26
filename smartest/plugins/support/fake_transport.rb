# frozen_string_literal: true

require "json"
require "openssl"

# Offline test doubles for the plugins contract suite. No live accounts, AI
# calls, or network services are used; all HTTP goes through FakeTransport.
module PluginsTestSupport
  # Scripted HTTP transport recording every request. Error mapping goes
  # through Http.raise_for_status! so fakes behave like NetHttpTransport.
  class FakeTransport
    Stub = Struct.new(:method, :pattern, :handler)

    attr_reader :requests

    def initialize(clock: Time)
      @clock = clock
      @requests = []
      @stubs = []
    end

    def stub_json(method, url_or_pattern, status: 200, body: {}, headers: {})
      response = Aiconshell::Plugins::Http::Response.new(
        status: status, headers: headers, body: JSON.generate(body)
      )
      @stubs << Stub.new(method.to_s.upcase, url_or_pattern, response)
      self
    end

    def stub_proc(method, url_or_pattern, &block)
      raise ArgumentError, "block required" unless block

      @stubs << Stub.new(method.to_s.upcase, url_or_pattern, block)
      self
    end

    def request(method:, url:, headers: {}, body: nil)
      entry = { method: method.to_s.upcase, url: url.to_s,
                headers: headers.to_h.dup, body: body }
      @requests << entry
      stub = @stubs.find { |candidate| match?(candidate, entry) }
      unless stub
        raise "no stub registered for #{entry[:method]} #{entry[:url]} " \
              "(#{@requests.size} request(s) recorded)"
      end

      response = stub.handler.respond_to?(:call) ? stub.handler.call(entry) : stub.handler
      Aiconshell::Plugins::Http.raise_for_status!(method, url, response, clock: @clock)
      response
    end

    def requests_to(url_or_pattern)
      @requests.select do |entry|
        case url_or_pattern
        when Regexp then url_or_pattern.match?(entry[:url])
        else entry[:url] == url_or_pattern.to_s
        end
      end
    end

    private

    def match?(stub, entry)
      return false unless stub.method == entry[:method]

      case stub.pattern
      when Regexp then stub.pattern.match?(entry[:url])
      else stub.pattern.to_s == entry[:url]
      end
    end
  end

  # Controllable clock injected as the registry `clock` collaborator.
  class FakeClock
    attr_accessor :now

    def initialize(now)
      @now = now
    end

    def advance(seconds)
      @now += seconds
      self
    end
  end

  # Lazily generated RSA key for GitHub App JWT tests (generated once per
  # suite run; never leaves the test process).
  module TestKeys
    class << self
      def github_private_key
        @github_private_key ||= OpenSSL::PKey::RSA.new(2048).to_pem
      end
    end
  end
end
