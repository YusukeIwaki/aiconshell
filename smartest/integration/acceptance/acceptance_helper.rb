# frozen_string_literal: true

require "db_helper"
require "fileutils"
require "json"
require "openssl"
require "rbconfig"
require "securerandom"
require "tmpdir"

# Self-contained fixtures for the bounded issue-9 acceptance slice.
#
# Only the outside world is fake at the boundary: a scripted HTTP transport
# (no network) and a temporary executable `claude` stand-in (no subscription
# login, no model call). All application code under test is real: the plugin
# Registry with the real Github adapter, the real Ai::Runner with the real
# ProcessRunner subprocess spawn, the real Interaction / Coordination /
# Execution services against real PostgreSQL tables and the real Solid Queue
# tables, and the real WorkflowEvents/EventLog boot wiring
# (config/initializers/event_log.rb -> EventLogging::OutboxAdapter ->
# EventDelivery rows). The event sink here is a recording wrapper that
# forwards every emit to that real path; it never mirrors calls in a
# collector instead of persisting them.
module AcceptanceHelper
  GH_API = "https://api.github.com"
  SCOPE = "o/r"
  FAKE_INSTALLATION_TOKEN = "fake-installation-token"

  ENV_KEYS = %w[
    PATH CLAUDE_CONFIG_DIR
    AICONSHELL_CLAUDE_HOME AICONSHELL_CLAUDE_BIN AICONSHELL_AI_HOME
    AICONSHELL_EXECUTION_ROOT AICONSHELL_ALLOWED_SCOPES AICONSHELL_DEMO_MODE
    AICONSHELL_LEASE_SECONDS AICONSHELL_AI_TIMEOUT_SECONDS
    AICONSHELL_SELF_ACTOR_IDS ACCEPTANCE_CANARY_SECRET
  ].freeze

  # Minimal scripted HTTP transport. Stubs match on method plus an exact URL
  # or Regexp; error mapping goes through Http.raise_for_status! so fakes
  # behave like NetHttpTransport. Every request is recorded for assertions.
  class ScriptedTransport
    Stub = Struct.new(:method, :pattern, :handler)

    attr_reader :requests

    def initialize
      @requests = []
      @stubs = []
    end

    def stub_json(method, pattern, status: 200, body: {}, headers: {})
      response = Aiconshell::Plugins::Http::Response.new(
        status: status, headers: headers, body: JSON.generate(body)
      )
      @stubs << Stub.new(method.to_s.upcase, pattern, response)
      self
    end

    def stub_proc(method, pattern, &block)
      raise ArgumentError, "block required" unless block

      @stubs << Stub.new(method.to_s.upcase, pattern, block)
      self
    end

    def request(method:, url:, headers: {}, body: nil)
      entry = { method: method.to_s.upcase, url: url.to_s,
                headers: headers.to_h.dup, body: body }
      @requests << entry
      stub = @stubs.find do |candidate|
        candidate.method == entry[:method] && match?(candidate.pattern, entry[:url])
      end
      raise "no stub registered for #{entry[:method]} #{entry[:url]}" unless stub

      response = stub.handler.respond_to?(:call) ? stub.handler.call(entry) : stub.handler
      Aiconshell::Plugins::Http.raise_for_status!(method, url, response)
      response
    end

    def requests_to(pattern)
      @requests.select do |entry|
        pattern.is_a?(Regexp) ? pattern.match?(entry[:url]) : entry[:url] == pattern.to_s
      end
    end

    private

    def match?(pattern, url)
      pattern.is_a?(Regexp) ? pattern.match?(url) : pattern.to_s == url
    end
  end

  # Recording wrapper around the REAL WorkflowEvents facade. Every emit is
  # recorded (for kind assertions) and forwarded to the real EventLog path,
  # and the real return value is kept: WorkflowEvents.emit returns the
  # persisted envelope on success and nil when the emit was dropped, so a
  # nil entry proves the real path rejected that emission instead of
  # silently passing.
  class RecordingEventSink
    attr_reader :events, :forwarded

    def initialize(target: WorkflowEvents)
      @target = target
      @events = []
      @forwarded = []
    end

    def emit(layer:, kind:, message:, task_id: nil, correlation_id: nil, data: {})
      @events << { layer: layer.to_s, kind: kind.to_s, message: message.to_s,
                   task_id: task_id, correlation_id: correlation_id,
                   data: data.is_a?(Hash) ? data : {} }
      result = @target.emit(layer: layer, kind: kind, message: message,
                            task_id: task_id, correlation_id: correlation_id,
                            data: data)
      @forwarded << result
      result
    end

    def kinds
      @events.map { |event| event[:kind] }
    end
  end

  # Fails fast unless the Rails boot wiring is the real EventLog outbox.
  # This deliberately does NOT reconfigure anything: if another suite file
  # leaked a fake outbox into the global config, that isolation bug must
  # fail loudly here instead of being papered over.
  def ensure_real_eventlog_wiring!
    raise "WorkflowEvents facade is not observable" unless WorkflowEvents.observability?

    outbox = Aiconshell::Observability.config.outbox
    return true if outbox.is_a?(EventLogging::OutboxAdapter)

    raise "real EventLog boot wiring missing: outbox is #{outbox.class} " \
      "(expected EventLogging::OutboxAdapter from config/initializers/event_log.rb)"
  end

  Context = Struct.new(:root, :execution_root, :bin, :claude_home, :evidence_path,
                       :transport, :plugin_env, :registry, :ai_runner, :sink,
                       keyword_init: true)

  def with_acceptance_env
    saved = ENV_KEYS.to_h { |key| [key, ENV[key]] }
    Dir.mktmpdir("aiconshell-acceptance-") do |root|
      built = build_claude_bin(root)
      execution_root = File.join(root, "execution")
      FileUtils.mkdir_p(execution_root)

      ENV["PATH"] = "#{built[:bin]}#{File::PATH_SEPARATOR}#{saved["PATH"]}"
      # Point the subscription-auth lookup at the temp home so the child can
      # never see real host auth. CLAUDE_CONFIG_DIR wins over the app key.
      ENV["CLAUDE_CONFIG_DIR"] = built[:claude_home]
      ENV["AICONSHELL_CLAUDE_HOME"] = built[:claude_home]
      ENV.delete("AICONSHELL_CLAUDE_BIN")
      ENV["AICONSHELL_AI_HOME"] = File.join(root, "controlled-home")
      ENV["AICONSHELL_EXECUTION_ROOT"] = execution_root
      ENV["AICONSHELL_ALLOWED_SCOPES"] = "github:#{SCOPE}"
      %w[AICONSHELL_DEMO_MODE AICONSHELL_LEASE_SECONDS AICONSHELL_AI_TIMEOUT_SECONDS
         AICONSHELL_SELF_ACTOR_IDS].each { |key| ENV.delete(key) }
      ENV["ACCEPTANCE_CANARY_SECRET"] = "canary-#{SecureRandom.hex(8)}"

      transport = ScriptedTransport.new
      plugin_env = {
        "GITHUB_APP_ID" => "123456",
        "GITHUB_INSTALLATION_ID" => "789",
        # Generated inside the test process; never leaves it.
        "GITHUB_PRIVATE_KEY" => OpenSSL::PKey::RSA.new(2048).to_pem
      }
      registry = Aiconshell::Plugins::Registry.new(env: plugin_env, transport: transport, clock: Time)
      registry.register(Aiconshell::Plugins::Github.new)
      yield Context.new(root: root, execution_root: execution_root, bin: built[:bin],
                        claude_home: built[:claude_home], evidence_path: built[:evidence],
                        transport: transport, plugin_env: plugin_env, registry: registry,
                        ai_runner: Aiconshell::Ai::Runner.new, sink: RecordingEventSink.new)
    end
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
  end

  # One JSON record per CLI invocation, in spawn order.
  def cli_evidence(path)
    return [] unless File.exist?(path)

    File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
  end

  def github_issue(number:, updated:, title:, body:, comments: 1)
    {
      "number" => number, "title" => title, "body" => body, "state" => "open",
      "comments" => comments, "updated_at" => updated,
      "html_url" => "https://github.com/#{SCOPE}/issues/#{number}",
      "user" => { "login" => "alice", "id" => 1, "type" => "User" }
    }
  end

  def github_comment(id:, body:, updated:, login: "alice")
    {
      "id" => id, "body" => body, "updated_at" => updated,
      "html_url" => "https://github.com/#{SCOPE}/issues/1#c#{id}",
      "user" => { "login" => login, "id" => 1, "type" => "User" }
    }
  end

  private

  # Temporary executable fake subscription CLI. It answers the three layer
  # prompts with schema-valid structured output and records program/argv/
  # stdin/cwd/pid plus the full child environment for boundary assertions.
  # The absolute ruby shebang keeps it runnable under the child's controlled
  # PATH.
  def build_claude_bin(root)
    bin = File.join(root, "bin")
    FileUtils.mkdir_p(bin)
    claude_home = File.join(root, "homes", "claude")
    FileUtils.mkdir_p(claude_home)
    evidence = File.join(root, "evidence.jsonl")
    File.write(File.join(bin, "claude"), <<~RUBY)
      #!#{RbConfig.ruby}
      # frozen_string_literal: true
      # Temporary acceptance double for the `claude` subscription CLI.
      require "json"
      evidence_path = #{evidence.dump}
      prompt = STDIN.binmode.read.to_s
      File.open(evidence_path, "a") do |f|
        f.puts(JSON.generate({ "program" => $PROGRAM_NAME, "argv" => ARGV, "stdin" => prompt,
                               "env" => ENV.to_h, "cwd" => Dir.pwd, "pid" => Process.pid }))
      end
      answer = if prompt.include?("You coordinate tasks")
        ids = prompt.scan(/"task_id"\\s*:\\s*(\\d+)/).flatten.map(&:to_i).uniq
        { "rulings" => ids.map do |id|
          { "task_id" => id, "priority" => 10, "status" => "ready",
            "dispatch" => true, "work_plan" => "Fix per reporter clarification; keep thread posted." }
        end }
      elsif prompt.include?("Execute this persisted work request")
        { "outcome" => "waiting_review", "summary" => "Fixed the login retry bug",
          "reply_body" => "Login retry fixed; please verify on Safari" }
      elsif prompt.include?("Draft a concise reply")
        original = prompt.split("Do not add promises:\\n", 2).last.to_s.strip
        { "body" => "drafted: \#{original}"[0, 4000] }
      else
        { "unrecognized" => true }
      end
      puts JSON.generate({ "type" => "result", "subtype" => "success", "structured_output" => answer })
    RUBY
    File.chmod(0o755, File.join(bin, "claude"))
    { bin: bin, claude_home: claude_home, evidence: evidence }
  end
end

include AcceptanceHelper
