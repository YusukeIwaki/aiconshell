# frozen_string_literal: true

module Aiconshell
  module Ai
    module Authentication
      # Incremental login-output scanner. Fed arbitrary stdout/stderr chunks,
      # it strips ANSI escapes (tolerating splits mid-sequence, and keeping
      # OSC 8 hyperlink targets so a styled URL is still found), normalizes
      # carriage returns, and derives:
      #
      # - the current device-code challenge (first policy-passing URL wins;
      #   a trailing URL that touches the buffer end stays pending until a
      #   delimiter arrives or the stream finishes, so chunk splits can never
      #   turn a URL prefix into a false rejection),
      # - fail-fast signals: policy-failing URLs (`foreign_url?`) and
      #   API-key/access-token markers (`api_key_hit?`),
      # - the stdin prompt flag for Claude (`input_required?`),
      # - an exit classification hint once the child is done (`exit_hint`).
      #
      # User-code extraction is heuristic and provider-specific; the URL
      # policy stays the security anchor and `user_code` may be nil. The
      # buffered text is for classification only — the Runner never returns
      # it.
      class Scanner
        URL_PATTERN = %r{https?://[^\s<>"'`]+}.freeze
        TRAILING_TRIM = %r{[.,;:!?'"()\[\]{}]+\z}.freeze
        OSC8_PATTERN = /\e\]8;[^\a\e\\;]*;([^\a\e\\]*)(?:\a|\e\\)/.freeze
        OSC_PATTERN = /\e\][^\a\e]*(?:\a|\e\\)/.freeze
        CSI_PATTERN = /\e\[[0-?]*[ -\/]*[@-~]/.freeze
        CHARSET_PATTERN = /\e[()][0-9A-B]/.freeze
        SINGLE_PATTERN = /\e[0-~]/.freeze
        TRAILING_OSC = /\e\][^\a\e]*\z/.freeze
        TRAILING_CSI = /\e(?:\[[0-?]*[ -\/]*)?\z/.freeze

        CODE_CONTEXT = /code|device|verify|approve|enter/i.freeze
        STRICT_CODE_CONTEXT = /code/i.freeze
        HYPHEN_CODE = /\b[A-Za-z0-9]{3,10}-[A-Za-z0-9]{3,10}\b/.freeze
        TOKEN_CODE = /\b[A-Za-z0-9][A-Za-z0-9-]{4,14}[A-Za-z0-9]\b/.freeze
        CLAUDE_PROMPT = /Paste code here if prompted/.freeze

        API_KEY_MARKERS = [
          /api[\s_-]?key/i,
          /access[\s_-]?token/i,
          /--with-api-key/,
          /--with-access-token/,
          /ANTHROPIC_API_KEY/,
          /OPENAI_API_KEY/,
          /CODEX_(API_KEY|ACCESS_TOKEN)/,
          /META_API_KEY/
        ].freeze

        EXPIRY_HINTS = [
          /code\s+expired/i,
          /verification[^\n]*expired/i,
          /device[^\n]*expired/i,
          /login[^\n]*expired/i,
          /flow\s+expired/i
        ].freeze

        AUTH_FAILURE_HINTS = [
          /login\s+(failed|cancelled|canceled|denied)/i,
          /authentication\s+(failed|error|denied)/i,
          /\bauth\s+(failed|error|denied)/i,
          /not\s+logged\s+in/i,
          /unauthori[sz]ed/i,
          /access\s+denied/i,
          /permission\s+denied/i,
          /user\s+(cancelled|canceled|denied)/i
        ].freeze

        attr_reader :bytes

        def initialize(provider)
          @provider = provider
          @bytes = 0
          @text = +""
          @pending_escape = +""
          @finished = false
        end

        def feed(chunk)
          return self if chunk.nil? || chunk.empty?

          raw = chunk.b
          @bytes += raw.bytesize
          append_stripped(raw)
          self
        end

        # Marks the stream finished: drops a dangling escape tail and lets a
        # trailing URL candidate finalize.
        def finish
          return self if @finished

          @finished = true
          @pending_escape = +""
          self
        end

        # Current challenge, or nil until a policy-passing URL is complete.
        def challenge
          urls = passing_urls
          return nil if urls.empty?

          {
            "verification_uri" => urls.first,
            "user_code" => current_code,
            "input_required" => input_required?
          }
        end

        def foreign_url?
          complete_candidates.any? { |candidate| UrlPolicy.validate(@provider, candidate).nil? }
        end

        def api_key_hit?
          API_KEY_MARKERS.any? { |pattern| pattern.match?(@text) }
        end

        def input_required?
          @provider == "claude" && CLAUDE_PROMPT.match?(@text)
        end

        # Exit classification once output is final: :expired, :auth_failed
        # or :unknown.
        def exit_hint
          return :expired if EXPIRY_HINTS.any? { |pattern| pattern.match?(@text) }
          return :auth_failed if AUTH_FAILURE_HINTS.any? { |pattern| pattern.match?(@text) }

          :unknown
        end

        private

        def append_stripped(raw)
          buffer = (@pending_escape + raw).force_encoding(Encoding::UTF_8).scrub
          held = +""
          if (match = buffer.match(TRAILING_OSC))
            held = match[0]
          elsif (match = buffer.match(TRAILING_CSI))
            held = match[0]
          end
          head = held.empty? ? buffer : buffer[0, buffer.length - held.length]
          # OSC 8 hyperlinks carry the URL as a parameter: keep the target,
          # drop the styling, before generic OSC stripping.
          head = head.gsub(OSC8_PATTERN, ' \1 ')
          head = head.gsub(OSC_PATTERN, "")
          head = head.gsub(CSI_PATTERN, "")
          head = head.gsub(CHARSET_PATTERN, "")
          head = head.gsub(SINGLE_PATTERN, "")
          head = head.gsub(/\r\n?/, "\n")
          @text << head
          @pending_escape = held
        end

        def complete_candidates
          candidates = []
          position = 0
          while (match = URL_PATTERN.match(@text, position))
            complete = @finished || match.end(0) < @text.length
            if complete
              trimmed = match[0].sub(TRAILING_TRIM, "")
              candidates << trimmed unless trimmed.empty?
            end
            position = match.end(0)
          end
          candidates
        end

        def passing_urls
          complete_candidates.filter_map { |candidate| UrlPolicy.validate(@provider, candidate) }.uniq
        end

        def current_code
          case @provider
          when "codex" then hyphen_code
          when "muse" then hyphen_code || token_code
          else nil
          end
        end

        # Code-bearing lines with URL substrings blanked, so opaque query
        # values can never be mistaken for the short user code.
        def code_lines(strict:)
          context = strict ? STRICT_CODE_CONTEXT : CODE_CONTEXT
          @text.each_line.select { |line| context.match?(line) }.map { |line| line.gsub(URL_PATTERN, " ") }
        end

        def hyphen_code
          code_lines(strict: false).each do |line|
            match = line.match(HYPHEN_CODE)
            return match[0] if match
          end
          nil
        end

        def token_code
          code_lines(strict: true).each do |line|
            line.scan(TOKEN_CODE) do |token|
              return token if token.match?(/\d/)
            end
          end
          nil
        end
      end
    end
  end
end
