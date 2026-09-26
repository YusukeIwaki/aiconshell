# frozen_string_literal: true

require "json"
require "stringio"

# Narrow body guard for /api/admin/task_requests and its receipt routes.
#
# Rails parses request parameters lazily, but ActionController instrumentation
# asks for filtered_parameters before the action and ActionDispatch logs the
# raw POST body at DEBUG when JSON parsing fails. Controller-level rescue
# alone cannot prevent a malformed body from reaching those logs.
#
# This middleware runs ahead of parameter parsing for this API collection
# routes only (any (.:format) suffix and optional trailing slash). It reads a
# bounded number of actual body bytes, parses JSON once, stashes the result
# for the controller, and replaces rack.input with an empty body so the
# framework never reparses the original bytes. It never returns a response
# itself, so API authentication failures (401) keep precedence over body errors.
# Receipt reads ignore the cached input, keeping their bodies out of logs too.
#
# Bound: 128 KiB of actual bytes read (not Content-Length). A valid maximum
# compact payload (title 500 + description 8000 Unicode chars) stays under this
# even when every astral char is JSON-escaped as surrogate pairs
# (12 bytes per char => ~102 KiB + JSON framing).
class ApiTaskRequestBodyGuard
  BASE_PATH = "/api/admin/task_requests"
  LIMIT_BYTES = 128 * 1024
  ENV_KEY = "aiconshell.api_task_request_guard"

  def initialize(app)
    @app = app
  end

  def call(env)
    unless guard_request?(env)
      return @app.call(env)
    end

    env[ENV_KEY] = parse_bounded(env)
    normalize_content_type(env)
    env["rack.input"] = StringIO.new("")
    env["CONTENT_LENGTH"] = "0"
    @app.call(env)
  end

  private

  def guard_request?(env)
    # Rails routing collapses repeated separators. Match the same aliases
    # before its instrumentation can parse or log the original body.
    path = env["PATH_INFO"].to_s.gsub(%r{/+}, "/")
    path == BASE_PATH || path.start_with?("#{BASE_PATH}/") || path.start_with?("#{BASE_PATH}.")
  end

  # Empty or slash-less Content-Type makes Rails MIME negotiation raise
  # InvalidType (406) before the controller runs. Normalize it to a valid
  # non-JSON type so the controller consistently returns 400 json_only
  # after auth. Valid types (including application/json) are untouched.
  def normalize_content_type(env)
    media = env["CONTENT_TYPE"].to_s.split(";").first.to_s.strip
    env["CONTENT_TYPE"] = "text/plain" unless media.include?("/")
  end

  def parse_bounded(env)
    raw = read_bounded(env["rack.input"])
    return { status: :oversized, data: nil } if raw.nil?

    media = env["CONTENT_TYPE"].to_s.split(";").first.to_s.strip.downcase
    return { status: :json_only, data: nil } unless media == "application/json"
    raw = raw.dup.force_encoding(Encoding::UTF_8)
    return { status: :malformed, data: nil } unless raw.valid_encoding?
    return { status: :malformed, data: nil } if raw.strip.empty?

    begin
      { status: :ok, data: JSON.parse(raw) }
    rescue StandardError
      { status: :malformed, data: nil }
    end
  end

  # Reads at most LIMIT_BYTES+1 actual bytes. Returns nil when the body is
  # larger than the bound, otherwise the raw string (binary-safe).
  def read_bounded(input)
    return "" if input.nil?

    chunk = input.read(LIMIT_BYTES + 1)
    return "" if chunk.nil?
    return nil if chunk.bytesize > LIMIT_BYTES

    chunk.b
  rescue StandardError
    ""
  end
end
