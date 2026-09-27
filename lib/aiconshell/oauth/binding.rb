# frozen_string_literal: true

module Aiconshell
  module Oauth
    # Secret-free credential binding handed to later plugins (issues
    # #24/#25/#26). It identifies one stored connection generation without
    # carrying any token: connection id, generation, provider, external
    # principal, and the fixed tenant/cloud. A token is issued only when the
    # binding still matches the stored row; mismatches are rejected before
    # any external write.
    class Binding
      FIELDS = %w[connection_id generation provider principal tenant cloud].freeze

      attr_reader :connection_id, :generation, :provider, :principal, :tenant, :cloud

      def initialize(connection_id:, generation:, provider:, principal:, tenant: nil, cloud: nil)
        @connection_id = connection_id
        @generation = generation.to_i
        @provider = provider.to_s
        @principal = principal.to_s
        @tenant = tenant.nil? ? nil : tenant.to_s
        @cloud = cloud.nil? ? nil : cloud.to_s
        freeze
      end

      def to_h
        {
          "connection_id" => @connection_id,
          "generation" => @generation,
          "provider" => @provider,
          "principal" => @principal,
          "tenant" => @tenant,
          "cloud" => @cloud
        }
      end

      def self.from_h(hash)
        return hash if hash.is_a?(Binding)

        source = hash.is_a?(Hash) ? hash : {}
        fetch = ->(key) { source[key.to_s].nil? ? source[key.to_sym] : source[key.to_s] }
        new(
          connection_id: fetch.call("connection_id"),
          generation: fetch.call("generation"),
          provider: fetch.call("provider"),
          principal: fetch.call("principal"),
          tenant: fetch.call("tenant"),
          cloud: fetch.call("cloud")
        )
      end

      # True only when every field matches the stored connection snapshot.
      # The caller supplies the snapshot as a plain Hash with the same keys
      # (plus no secrets); unknown or blank bindings never match.
      def matches?(snapshot)
        return false unless snapshot.is_a?(Hash)
        return false if @provider.empty? || @principal.empty?
        return false if @connection_id.nil? || @generation.nil?

        get = ->(key) do
          value = snapshot[key.to_s]
          value = snapshot[key.to_sym] if value.nil?
          value
        end
        get.call("connection_id").to_s == @connection_id.to_s &&
          get.call("generation").to_i == @generation &&
          get.call("provider").to_s == @provider &&
          get.call("principal").to_s == @principal &&
          normalize(get.call("tenant")) == normalize(@tenant) &&
          normalize(get.call("cloud")) == normalize(@cloud)
      end

      def inspect
        "#<Aiconshell::Oauth::Binding provider=#{@provider.inspect} " \
          "principal=#{redacted_principal.inspect} generation=#{@generation.inspect}>"
      end

      private

      def normalize(value)
        value.nil? ? nil : value.to_s
      end

      def redacted_principal
        return "" if @principal.empty?

        "#{@principal[0]}…(#{@principal.length})"
      end
    end
  end
end
