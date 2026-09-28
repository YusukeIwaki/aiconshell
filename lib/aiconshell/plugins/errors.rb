# frozen_string_literal: true

module Aiconshell
  module Plugins
    # Base class for all plugin errors. Every failure mode surfaced by
    # Registry#invoke uses a typed subclass so callers can branch without
    # parsing messages. Messages never include credential values.
    class Error < StandardError; end

    # Unknown plugin id passed to Registry#invoke.
    class UnknownPlugin < Error
      attr_reader :plugin

      def initialize(plugin)
        @plugin = plugin.to_s
        super("unknown plugin: #{@plugin.inspect}")
      end
    end

    # Unknown operation name for a known plugin.
    class UnknownOperation < Error
      attr_reader :plugin, :operation

      def initialize(plugin:, operation:)
        @plugin = plugin.to_s
        @operation = operation.to_s
        super("unknown operation #{@operation.inspect} for plugin #{@plugin.inspect}")
      end
    end

    # Operation is known but explicitly unsupported by the plugin
    # (e.g. Discord create_issue). A subclass of UnknownOperation so generic
    # handlers keep working.
    class UnsupportedOperation < UnknownOperation
      attr_reader :reason

      def initialize(plugin:, operation:, reason: nil)
        @reason = reason
        super(plugin: plugin, operation: operation)
      end

      def message
        base = "unsupported operation #{operation.inspect} for plugin #{plugin.inspect}"
        reason ? "#{base}: #{reason}" : base
      end
    end

    # Required credentials (or endpoint configuration) are missing or invalid.
    # Only environment variable *names* are reported, never values.
    class CredentialsMissing < Error
      attr_reader :plugin, :missing

      def initialize(plugin:, missing:)
        @plugin = plugin.to_s
        @missing = Array(missing).map(&:to_s)
        super("missing credentials for plugin #{@plugin.inspect}: #{@missing.join(", ")}")
      end
    end

    # The trusted context did not grant the scope required by the operation.
    class PermissionDenied < Error
      attr_reader :plugin, :operation, :required_scope

      def initialize(plugin:, operation:, required_scope:)
        @plugin = plugin.to_s
        @operation = operation.to_s
        @required_scope = required_scope.to_s
        super("permission denied for #{@plugin}##{@operation}: " \
              "required scope #{@required_scope.inspect} is not granted")
      end
    end

    # Input failed JSON Schema validation (or plugin-level shape checks).
    # Raised before any external I/O is attempted.
    class InputInvalid < Error
      attr_reader :plugin, :operation, :details

      def initialize(plugin:, operation:, details:)
        @plugin = plugin.to_s
        @operation = operation.to_s
        @details = Array(details).map(&:to_s)
        super("invalid input for #{@plugin}##{@operation}: #{@details.first(3).join("; ")}")
      end
    end

    # Plugin output failed JSON Schema validation. Either the adapter or the
    # remote API produced an unexpected shape.
    class OutputInvalid < Error
      attr_reader :plugin, :operation, :details

      def initialize(plugin:, operation:, details:)
        @plugin = plugin.to_s
        @operation = operation.to_s
        @details = Array(details).map(&:to_s)
        super("invalid output for #{@plugin}##{@operation}: #{@details.first(3).join("; ")}")
      end
    end

    # Non-2xx HTTP response. The URL is sanitized (query/fragment stripped)
    # and no request headers or bodies are included.
    class HttpError < Error
      attr_reader :status, :http_method, :url, :retry_after

      def initialize(status:, http_method:, url:, retry_after: nil)
        @status = status
        @http_method = http_method.to_s.upcase
        @url = Http.sanitize_url(url)
        @retry_after = retry_after
        message = "HTTP #{@status} from #{@http_method} #{@url}"
        message += " (retry after #{@retry_after}s)" if @retry_after
        super(message)
      end
    end

    # Rate limiting: HTTP 429, or 403 with an exhausted rate-limit budget.
    class RateLimited < HttpError; end

    # Connection/read/write timeout from the HTTP transport.
    class TransportTimeout < Error
      attr_reader :http_method, :url

      def initialize(http_method:, url:, timeout_kind:)
        @http_method = http_method.to_s.upcase
        @url = Http.sanitize_url(url)
        super("HTTP #{timeout_kind} timeout for #{@http_method} #{@url}")
      end
    end

    # Low-level network failure (DNS, connection refused, TLS, ...).
    # The cause is curated to a short single line so server response text
    # or credentials can never leak through exception messages.
    class TransportError < Error
      attr_reader :http_method, :url

      def initialize(http_method:, url:, cause_message: nil)
        @http_method = http_method.to_s.upcase
        @url = Http.sanitize_url(url)
        message = "HTTP transport failure for #{@http_method} #{@url}"
        curated = cause_message.nil? ? nil : Http.curate_cause(cause_message)
        message += ": #{curated}" if curated && !curated.empty?
        super(message)
      end
    end

    # A URL taken from a cursor or a paged API response pointed at a host
    # outside the plugin allowlist. Raised before any request is sent, so no
    # credential is ever forwarded to an unexpected host.
    class HostRejected < Error
      attr_reader :host, :allowed_hosts

      def initialize(host:, allowed_hosts:)
        @host = host.to_s
        @allowed_hosts = Array(allowed_hosts).map(&:to_s)
        super("refusing to send request to unexpected host #{@host.inspect}; " \
              "allowed: #{@allowed_hosts.join(", ")}")
      end
    end

    # A poll hit a configured page/item bound before the remote listing was
    # exhausted. No partial cursor is returned: the caller keeps its previous
    # cursor and retries with a narrower scope or after processing the backlog
    # (see each adapter README, "Incomplete polls"). Carries no event data,
    # no server text, and no credentials.
    class IncompletePoll < Error
      attr_reader :plugin, :operation, :reason

      def initialize(plugin:, operation:, reason:)
        @plugin = plugin.to_s
        @operation = operation.to_s
        @reason = reason.to_s
        super("incomplete poll for #{@plugin}##{@operation}: #{@reason}")
      end
    end

    # A response body exceeded the transport byte bound while streaming.
    # Raised before the full body is buffered.
    class ResponseTooLarge < TransportError
      attr_reader :limit_bytes

      def initialize(http_method:, url:, limit_bytes:)
        @limit_bytes = limit_bytes
        super(http_method: http_method, url: url,
              cause_message: "response body exceeded #{limit_bytes} bytes")
      end
    end
  end
end
