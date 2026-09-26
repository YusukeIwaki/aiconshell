# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "json"
require "time"

module Aiconshell
  module Plugins
    # Small HTTP layer shared by all adapters.
    #
    # Transports implement one method:
    #
    #   request(method:, url:, headers:, body:) -> Http::Response
    #
    # and raise typed errors (HttpError/RateLimited/TransportTimeout/
    # TransportError). Redirects are never followed automatically so an
    # Authorization header can never leak to another origin via redirect.
    module Http
      # Immutable response value. Headers are normalized to lowercase names.
      class Response
        attr_reader :status, :headers, :body

        def initialize(status:, headers: {}, body: "")
          @status = status
          @headers = headers.to_h.transform_keys { |key| key.to_s.downcase }
          @headers.freeze
          @body = body.to_s
          freeze
        end

        def header(name)
          @headers[name.to_s.downcase]
        end

        # Parsed JSON body, or nil for empty bodies. Raises OutputInvalid-style
        # JSON errors as-is; adapters convert unexpected shapes to typed errors.
        def json
          return nil if @body.empty?

          JSON.parse(@body)
        end
      end

      DEFAULT_OPEN_TIMEOUT = 5
      DEFAULT_READ_TIMEOUT = 15
      DEFAULT_WRITE_TIMEOUT = 15
      MAX_BODY_BYTES = 8 * 1024 * 1024

      # Production transport on top of Net::HTTP.
      class NetHttpTransport
        def initialize(open_timeout: DEFAULT_OPEN_TIMEOUT,
                       read_timeout: DEFAULT_READ_TIMEOUT,
                       write_timeout: DEFAULT_WRITE_TIMEOUT,
                       clock: Time)
          @open_timeout = open_timeout
          @read_timeout = read_timeout
          @write_timeout = write_timeout
          @clock = clock
        end

        def request(method:, url:, headers: {}, body: nil)
          uri = parse_uri!(method, url)
          payload = body.nil? ? nil : body.to_s
          net_response = perform(method, uri, headers, payload)
          response = Response.new(
            status: net_response.code.to_i,
            headers: extract_headers(net_response),
            body: net_response.body.to_s
          )
          Http.raise_for_status!(method, url, response, clock: @clock)
          response
        rescue TransportTimeout, TransportError, HttpError, RateLimited
          raise
        rescue JSON::ParserError
          raise # never raised here; parsing is lazy via Response#json
        end

        private

        def parse_uri!(method, url)
          uri = URI.parse(url.to_s)
          unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
            raise TransportError.new(http_method: method, url: url,
                                     cause_message: "unsupported URL")
          end
          uri
        rescue URI::InvalidURIError => e
          raise TransportError.new(http_method: method, url: url,
                                   cause_message: "invalid URL (#{e.message})")
        end

        def perform(method, uri, headers, payload)
          Net::HTTP.start(uri.host, uri.port,
                          use_ssl: uri.scheme == "https",
                          open_timeout: @open_timeout,
                          read_timeout: @read_timeout,
                          write_timeout: @write_timeout) do |http|
            request = net_request_class(method).new(uri.request_uri)
            headers.each { |name, value| request[name.to_s] = value.to_s }
            request.body = payload if payload
            http.request(request)
          end
        rescue Net::OpenTimeout
          raise TransportTimeout.new(http_method: method, url: uri.to_s,
                                     timeout_kind: "connect")
        rescue Net::ReadTimeout
          raise TransportTimeout.new(http_method: method, url: uri.to_s,
                                     timeout_kind: "read")
        rescue Net::WriteTimeout
          raise TransportTimeout.new(http_method: method, url: uri.to_s,
                                     timeout_kind: "write")
        rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError => e
          raise TransportError.new(http_method: method, url: uri.to_s,
                                   cause_message: "#{e.class}: #{e.message}")
        end

        def net_request_class(method)
          case method.to_s.upcase
          when "GET" then Net::HTTP::Get
          when "POST" then Net::HTTP::Post
          when "PUT" then Net::HTTP::Put
          when "PATCH" then Net::HTTP::Patch
          when "DELETE" then Net::HTTP::Delete
          else raise ArgumentError, "unsupported HTTP method: #{method.inspect}"
          end
        end

        def extract_headers(net_response)
          headers = {}
          net_response.each_header do |name, value|
            key = name.to_s.downcase
            headers[key] = headers.key?(key) ? "#{headers[key]}, #{value}" : value.to_s
          end
          headers
        end
      end

      class << self
        # Raise HttpError/RateLimited for non-2xx responses. Shared by the
        # production transport and test fakes so error mapping is identical.
        def raise_for_status!(method, url, response, clock: Time)
          status = response.status
          return response if status >= 200 && status < 300

          retry_after = parse_retry_after(response.header("retry-after"), clock: clock)
          if status == 429 || rate_limit_exhausted?(response)
            raise RateLimited.new(status: status, http_method: method, url: url,
                                  retry_after: retry_after)
          end

          raise HttpError.new(status: status, http_method: method, url: url,
                              retry_after: retry_after)
        end

        # Parse a Retry-After value (delay seconds or HTTP date) into seconds.
        def parse_retry_after(value, clock: Time)
          return nil if value.nil? || value.to_s.strip.empty?

          text = value.to_s.strip
          return text.to_i if text.match?(/\A\d+\z/)

          begin
            delta = Time.httpdate(text) - clock.now
            delta <= 0 ? 0 : delta.ceil
          rescue ArgumentError
            nil
          end
        end

        # Guard a URL taken from a cursor or an API payload (Link header,
        # nextPage, @odata.nextLink) against the plugin host allowlist.
        # Returns the parsed URI. Raises HostRejected before any I/O.
        def check_host!(url, allowed_hosts)
          uri = URI.parse(url.to_s)
          host = uri.host.to_s.downcase
          allowed = Array(allowed_hosts).map { |entry| entry.to_s.downcase }
          unless uri.is_a?(URI::HTTP) && !host.empty? && allowed.include?(host)
            raise HostRejected.new(host: host.empty? ? url.to_s : host,
                                   allowed_hosts: allowed_hosts)
          end
          uri
        rescue URI::InvalidURIError
          raise HostRejected.new(host: url.to_s, allowed_hosts: allowed_hosts)
        end

        # Strip query/fragment for safe use in error messages and logs.
        def sanitize_url(url)
          uri = URI.parse(url.to_s)
          return "(invalid url)" unless uri.host

          clean = "#{uri.scheme}://#{uri.host}"
          clean += ":#{uri.port}" if uri.port && uri.port != uri.default_port
          clean + (uri.path.empty? ? "/" : uri.path)
        rescue URI::InvalidURIError
          "(invalid url)"
        end

        # Extract the rel="next" target from a Link response header.
        def next_link(headers)
          link = headers["link"] || headers["Link"]
          return nil if link.nil?

          link.to_s.split(",").each do |part|
            segments = part.strip.split(";").map(&:strip)
            target = segments[0]
            rels = segments[1..]
            next unless target.start_with?("<") && target.end_with?(">")

            return target[1..-2] if rels.any? { |rel| rel.match?(/\Arel\s*=\s*"?next"?\z/i) }
          end
          nil
        end

        private

        def rate_limit_exhausted?(response)
          return false unless response.status == 403

          remaining = response.header("x-ratelimit-remaining") ||
                      response.header("ratelimit-remaining")
          return true if !remaining.nil? && remaining.to_s.strip == "0"

          retry_after = response.header("retry-after")
          !retry_after.nil? && !retry_after.to_s.strip.empty?
        end
      end
    end
  end
end
