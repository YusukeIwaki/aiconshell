# frozen_string_literal: true

# Schedule this no-argument control job every five minutes in Solid Queue.
# It only enumerates AICONSHELL_ALLOWED_SCOPES; it never discovers or expands
# destinations remotely. Concrete poll scopes are github:owner/repo and
# discord:channel/<channelId>.
# Registered custom plugins may declare other concrete scope formats through
# their latest_events input schema, which is checked before every enqueue.
#
# There is no separate polling-enable flag. An empty allowlist disables
# polling. Interaction LayerPolicy controls AI drafting, not event ingestion.
# Unknown, unconfigured, unsupported, wildcard, and write-only destinations
# are skipped; a later tick rechecks configuration. Plugin login/permission
# failures after enqueue remain visible on IntegrationCursor via PollService.
# Duplicate scheduled jobs are safe because PollService fences cursor leases
# and ingests event fingerprints idempotently.
class IntegrationPollScheduleJob < ApplicationJob
  queue_as :control

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform
    catalog = plugin_registry.catalog.index_by { |entry| entry.fetch("id") }
    scheduled = 0
    WorkflowSettings.allowed_scopes.each do |plugin, scopes|
      entry = catalog[plugin]
      next unless entry
      next unless schedule_configured?(plugin, entry)

      operation = entry.fetch("operations").find { |candidate| candidate["name"] == "latest_events" }
      next unless operation && !operation["unsupported"]
      input_schema = JSONSchemer.schema(operation.fetch("input_schema"))

      scopes.each do |scope|
        next unless concrete_poll_scope?(plugin, scope)
        next unless input_schema.valid?({ "scope" => scope })

        InteractionPollJob.perform_later(plugin, scope)
        scheduled += 1
      end
    end
    scheduled
  end

  private

  def plugin_registry
    Aiconshell::Plugins::Registry.default
  end

  # Built-in plugins read the database-backed accounts; registered
  # extensions keep their own configured flag from the catalog.
  def schedule_configured?(plugin, entry)
    return Accounts.configured?(plugin) if Accounts::PLUGINS.include?(plugin.to_s)

    entry["configured"]
  end

  def concrete_poll_scope?(plugin, scope)
    # Glob characters and encoded/whitespace destinations are never expanded.
    return false unless scope.is_a?(String) && !scope.empty? && !scope.match?(/[\s*?\[\]{}\\%]/)

    case plugin
    when "github"
      # Exclude resource IDs and URLs accepted by the plugin's broad parser.
      scope.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}) &&
        scope.split("/").none? { |part| %w[. ..].include?(part) }
    when "discord"
      match = Aiconshell::Plugins::Discord::SCOPE_PATTERN.match(scope)
      match && Aiconshell::Plugins::Discord.valid_snowflake?(match[:channel])
    else
      true
    end
  end
end
