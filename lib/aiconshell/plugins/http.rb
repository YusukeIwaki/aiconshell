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

      # Production transport on top of Net::HTTP. Response bodies are read
      # with a streaming byte bound (MAX_BODY_BYTES by default); oversize
      # bodies raise ResponseTooLarge before they are fully buffered.
      class NetHttpTransport
        def initialize(open_timeout: DEFAULT_OPEN_TIMEOUT,
                       read_timeout: DEFAULT_READ_TIMEOUT,
                       write_timeout: DEFAULT_WRITE_TIMEOUT,
                       clock: Time,
                       max_body_bytes: MAX_BODY_BYTES)
          @open_timeout = open_timeout
          @read_timeout = read_timeout
          @write_timeout = write_timeout
          @clock = clock
          @max_body_bytes = max_body_bytes
        end

        def request(method:, url:, headers: {}, body: nil)
          uri = parse_uri!(method, url)
          payload = body.nil? ? nil : body.to_s
          status, resp_headers, resp_body = perform(method, uri, headers, payload)
          response = Response.new(
            status: status,
            headers: resp_headers,
            body: resp_body
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
          if uri.userinfo && !uri.userinfo.empty?
            raise TransportError.new(http_method: method, url: url,
                                     cause_message: "URL must not contain userinfo")
          end
          uri
        rescue URI::InvalidURIError
          # Never echo the raw parser message: it can contain the input URL.
          raise TransportError.new(http_method: method, url: url,
                                   cause_message: "invalid URL")
        end

        def perform(method, uri, headers, payload)
          result = nil
          Net::HTTP.start(uri.host, uri.port,
                          use_ssl: uri.scheme == "https",
                          open_timeout: @open_timeout,
                          read_timeout: @read_timeout,
                          write_timeout: @write_timeout) do |http|
            request = net_request_class(method).new(uri.request_uri)
            headers.each { |name, value| request[name.to_s] = value.to_s }
            request.body = payload if payload
            http.request(request) do |net_response|
              result = read_bounded!(method, uri, net_response)
            end
          end
          unless result
            raise TransportError.new(http_method: method, url: uri.to_s,
                                     cause_message: "empty response")
          end
          result
        rescue ResponseTooLarge, TransportTimeout
          raise
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

        # Read a response body in chunks, enforcing @max_body_bytes. A
        # declared Content-Length over the bound fails fast without reading.
        def read_bounded!(method, uri, net_response)
          headers = {}
          net_response.each_header do |name, value|
            key = name.to_s.downcase
            headers[key] = headers.key?(key) ? "#{headers[key]}, #{value}" : value.to_s
          end
          declared = headers["content-length"].to_s.strip
          if declared.match?(/\A\d+\z/) && declared.to_i > @max_body_bytes
            raise ResponseTooLarge.new(http_method: method, url: uri.to_s,
                                       limit_bytes: @max_body_bytes)
          end
          buf = +""
          net_response.read_body do |chunk|
            buf << chunk
            next unless buf.bytesize > @max_body_bytes

            raise ResponseTooLarge.new(http_method: method, url: uri.to_s,
                                       limit_bytes: @max_body_bytes)
          end
          [net_response.code.to_i, headers, buf]
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
        # Fractional delay seconds (for example Discord's decimal
        # Retry-After) are rounded up; non-finite values are ignored.
        def parse_retry_after(value, clock: Time)
          return nil if value.nil? || value.to_s.strip.empty?

          text = value.to_s.strip
          if text.match?(/\A\d+(?:\.\d+)?\z/)
            seconds = text.to_f
            return seconds.ceil if seconds.finite?

            return nil
          end

          begin
            delta = Time.httpdate(text) - clock.now
            delta <= 0 ? 0 : delta.ceil
          rescue ArgumentError
            nil
          end
        end

        # Guard a URL taken from a cursor or an API payload (Link header,
        # nextPage, @odata.nextLink) against trusted origins before any
        # credentialed request is sent. Returns the parsed URI.
        #
        # Allowed entries are full origins ("https://api.example.com",
        # "https://host:8443/base") or, for the production default, a bare
        # hostname meaning https with the default port. Scheme, host
        # (case-insensitive), and effective port must all match, so an
        # https origin never silently downgrades to http and a same-host
        # wrong-port URL is rejected. URLs carrying userinfo are always
        # rejected. Plain-http loopback origins are accepted only when the
        # caller explicitly lists that exact loopback origin (test
        # injection); they are never implied by a bare hostname.
        def check_host!(url, allowed_hosts)
          allowed = Array(allowed_hosts)
          begin
            uri = URI.parse(url.to_s)
          rescue URI::InvalidURIError
            raise HostRejected.new(host: "(invalid url)", allowed_hosts: allowed)
          end
          host = uri.host.to_s.downcase
          unless uri.is_a?(URI::HTTP) && !host.empty?
            raise HostRejected.new(host: "(invalid url)", allowed_hosts: allowed)
          end
          if uri.userinfo && !uri.userinfo.empty?
            raise HostRejected.new(host: host, allowed_hosts: allowed)
          end
          matched = allowed.any? { |entry| origin_allowed?(uri, entry) }
          unless matched
            raise HostRejected.new(host: host, allowed_hosts: allowed)
          end
          uri
        end

        # True when the candidate URI matches one allowlist entry: same
        # scheme, same host, same effective port. Bare hostnames mean
        # https + 443; anything else must be an explicit http(s) origin.
        def origin_allowed?(uri, entry)
          text = entry.to_s.strip
          return false if text.empty?

          if text.match?(%r{\Ahttps?://}i)
            begin
              base = URI.parse(text)
            rescue URI::InvalidURIError
              return false
            end
            return false unless base.is_a?(URI::HTTP) && base.host && !base.host.empty?
            return false if base.userinfo && !base.userinfo.empty?
            return false unless uri.scheme.to_s.downcase == base.scheme.to_s.downcase
            return false unless uri.host.to_s.downcase == base.host.to_s.downcase

            return uri.port == base.port
          end

          uri.scheme.to_s.downcase == "https" &&
            uri.host.to_s.downcase == text.downcase &&
            uri.port == 443
        end

        # Only application-authored reasons are safe to expose. Network and
        # parser messages can contain credentials or arbitrary response text.
        SAFE_CAUSES = ["unsupported URL", "invalid URL", "URL must not contain userinfo", "empty response"].freeze

        def curate_cause(message)
          text = message.to_s
          return text if SAFE_CAUSES.include?(text)
          return text if text.match?(/\Aresponse body exceeded \d+ bytes\z/)

          "network I/O failed"
        end

        # Parse a response body as JSON, converting parser failures to a
        # bounded OutputInvalid that never echoes server text.
        def strict_json!(body, plugin:, operation:)
          return nil if body.nil? || body.to_s.empty?

          JSON.parse(body.to_s)
        rescue JSON::ParserError
          raise OutputInvalid.new(plugin: plugin, operation: operation,
                                  details: ["response was not valid JSON"])
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
