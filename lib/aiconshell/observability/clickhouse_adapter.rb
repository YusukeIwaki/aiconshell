# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"

module Aiconshell
  module Observability
    # Minimal ClickHouse HTTP adapter: batch JSONEachRow inserts and
    # parameterized search reads. All user-controlled values travel as
    # `{name:Type}` query parameters; nothing is interpolated into SQL except
    # validated identifiers and clamped integers.
    class ClickHouseAdapter
      DEFAULT_TABLE = "event_log"
      DEFAULT_LIMIT = 100
      MAX_LIMIT = 1000
      IDENTIFIER_PATTERN = /\A[a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*\z/

      Response = Struct.new(:status, :body)

      # transport: callable receiving (method:, uri:, body:) and returning a
      # Response. Inject a fake in tests; default uses Net::HTTP.
      def initialize(base_url:, database:, table: DEFAULT_TABLE,
                     username: nil, password: nil,
                     open_timeout: 5, read_timeout: 15, transport: nil)
        @base_url = base_url
        @database = database
        @table = validate_table!(table)
        @username = username
        @password = password
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @transport = transport || method(:default_transport)
      end

      attr_reader :base_url, :database, :table

      def insert(envelopes)
        rows = Array(envelopes)
        return 0 if rows.empty?

        rows.each { |row| validate_insert_row!(row) }
        body = "#{rows.map { |row| JSON.generate(insert_row(row)) }.join("\n")}\n"
        uri = build_uri("query" => "INSERT INTO #{quoted_table} FORMAT JSONEachRow")
        response = request(:post, uri, body)
        ensure_success!(response, "insert #{rows.size} row(s)")
        rows.size
      end

      # Search mirrors Aiconshell::Observability.search plus an optional
      # event_id lookup for idempotent re-reads. Returns newest-first
      # envelope-like Hashes.
      def search(query: nil, layer: nil, kind: nil, task_id: nil,
                 correlation_id: nil, event_id: nil,
                 since: nil, until_time: nil, limit: DEFAULT_LIMIT)
        conditions, params = search_conditions(
          query:, layer:, kind:, task_id:,
          correlation_id:, event_id:, since:, until_time:
        )
        where = conditions.empty? ? "" : "WHERE #{conditions.join(" AND ")}"
        sql = <<~SQL.gsub(/\s+/, " ").strip
          SELECT event_id, layer, kind, message, data_json, task_id,
                 correlation_id, occurred_at, version
          FROM #{quoted_table} FINAL #{where}
          ORDER BY occurred_at DESC LIMIT #{clamp_limit(limit)} FORMAT JSON
        SQL
        uri = build_uri(params)
        response = request(:post, uri, sql)
        ensure_success!(response, "search")
        parse_search_response(response.body)
      end

      def exists?(event_id)
        !search(event_id:, limit: 1).empty?
      end

      private

      def validate_table!(table)
        raise ArgumentError, "table must be a String" unless table.is_a?(String)
        raise ArgumentError, "invalid table name #{table.inspect}" unless table.match?(IDENTIFIER_PATTERN)

        table
      end

      def quoted_table
        @table.split(".").map { |part| "`#{part}`" }.join(".")
      end

      def validate_insert_row!(row)
        raise ArgumentError, "insert rows must be Hashes" unless row.is_a?(Hash)

        %w[event_id layer kind message occurred_at data].each do |key|
          raise ArgumentError, "insert row missing #{key}" if row[key].nil?
        end
      end

      def insert_row(envelope)
        {
          "event_id" => envelope["event_id"],
          "layer" => envelope["layer"],
          "kind" => envelope["kind"],
          "message" => envelope["message"],
          "data_json" => JSON.generate(envelope["data"] || {}),
          "task_id" => envelope["task_id"],
          "correlation_id" => envelope["correlation_id"],
          "occurred_at" => envelope["occurred_at"],
          "version" => envelope["version"] || Envelope::VERSION
        }
      end

      def search_conditions(query:, layer:, kind:, task_id:, correlation_id:, event_id:, since:, until_time:)
        conditions = []
        params = {}
        add = lambda do |sql, name, value|
          conditions << sql
          params["param_#{name}"] = value
        end

        validate_layer!(layer)
        add.call("layer = {flt_layer:String}", "flt_layer", layer) unless layer.nil?
        add.call("kind = {flt_kind:String}", "flt_kind", kind) unless kind.nil?
        unless task_id.nil?
          raise ArgumentError, "task_id must be an Integer" unless task_id.is_a?(Integer)

          add.call("task_id = {flt_task:Int64}", "flt_task", task_id.to_s)
        end
        unless correlation_id.nil?
          add.call("correlation_id = {flt_corr:String}", "flt_corr", correlation_id.to_s)
        end
        add.call("event_id = {flt_event:String}", "flt_event", event_id.to_s) unless event_id.nil?
        add.call("occurred_at >= parseDateTime64BestEffort({flt_since:String})",
                 "flt_since", canonical_time!(since, "since")) unless since.nil?
        add.call("occurred_at <= parseDateTime64BestEffort({flt_until:String})",
                 "flt_until", canonical_time!(until_time, "until_time")) unless until_time.nil?
        unless query.nil? || query.to_s.empty?
          conditions << "(position(message, {flt_q:String}) > 0 OR position(kind, {flt_q:String}) > 0)"
          params["param_flt_q"] = query.to_s
        end
        [conditions, params]
      end

      def validate_layer!(layer)
        return if layer.nil?
        return if Envelope::LAYERS.include?(layer.to_s)

        raise ArgumentError, "layer must be one of #{Envelope::LAYERS.join(", ")}"
      end

      def canonical_time!(value, name)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(3)
      rescue ArgumentError
        raise ArgumentError, "#{name} must be a Time or ISO8601 String"
      end

      def clamp_limit(limit)
        int = Integer(limit)
        [[int, 1].max, MAX_LIMIT].min
      rescue ArgumentError, TypeError
        raise ArgumentError, "limit must be an Integer 1..#{MAX_LIMIT}"
      end

      def build_uri(extra_params)
        uri = URI.parse(@base_url)
        query_params = URI.decode_www_form(uri.query.to_s).to_h
        query_params["database"] = @database
        extra_params.each { |key, value| query_params[key] = value }
        uri.query = URI.encode_www_form(query_params)
        uri
      end

      def request(http_method, uri, body)
        @transport.call(method: http_method, uri:, body:)
      rescue ClickHouseError
        raise
      rescue StandardError => e
        raise ClickHouseError, "clickhouse #{uri.host} request failed: #{Redaction.sanitize_error(e)}"
      end

      def default_transport(method:, uri:, body:)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        request_class = method == :post ? Net::HTTP::Post : Net::HTTP::Get
        req = request_class.new(uri.request_uri)
        req.basic_auth(@username, @password) unless @username.nil?
        req["Content-Type"] = "text/plain; charset=utf-8"
        req.body = body
        response = http.request(req)
        Response.new(response.code.to_i, response.body.to_s)
      end

      def ensure_success!(response, action)
        return if response.status == 200

        detail = Redaction.truncate_string(response.body.to_s.gsub(/\s+/, " ").strip, 300)
        raise ClickHouseError, "clickhouse #{action} failed (HTTP #{response.status}): #{detail}"
      end

      def parse_search_response(body)
        payload = JSON.parse(body)
        Array(payload["data"]).map { |row| normalize_row(row) }
      rescue JSON::ParserError => e
        raise ClickHouseError, "clickhouse search returned invalid JSON: #{Redaction.sanitize_error(e)}"
      end

      def normalize_row(row)
        {
          "event_id" => row["event_id"],
          "layer" => row["layer"],
          "kind" => row["kind"],
          "message" => row["message"],
          "task_id" => row["task_id"],
          "correlation_id" => row["correlation_id"],
          "occurred_at" => row["occurred_at"].to_s,
          "data" => parse_data_json(row["data_json"]),
          "version" => row["version"] || Envelope::VERSION
        }
      end

      def parse_data_json(raw)
        return {} if raw.nil? || raw.to_s.empty?

        JSON.parse(raw.to_s)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
