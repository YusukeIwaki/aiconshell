# frozen_string_literal: true

require_relative "ai_test_helper"

Ai = Aiconshell::Ai

test("registry always lists the three fixed providers") do
  AiTestSupport.with_tmpdir do |root|
    bin = AiTestSupport.make_bin(root, [])
    AiTestSupport.with_env("PATH" => bin) do
      config = AiTestSupport.make_config(root, bin: bin)
      registry = Ai::Registry.new(config: config)
      expect(registry.providers).to eq(%w[claude codex muse])
    end
  end
end

test("catalog entries carry id, name, executable and configured flag") do
  AiTestSupport.with_tmpdir do |root|
    bin = AiTestSupport.make_bin(root, %w[claude codex muse])
    AiTestSupport.with_env("PATH" => bin) do
      config = AiTestSupport.make_config(root, bin: bin)
      catalog = Ai::Registry.new(config: config).catalog
      expect(catalog.map { |entry| entry[:id] }).to eq(%w[claude codex muse])
      expect(catalog.map { |entry| entry[:name] }).to eq(["Claude Code", "Codex", "Muse Code"])
      expect(catalog.all? { |entry| entry[:configured] == true }).to eq(true)
      expect(catalog.all? { |entry| entry[:executable].is_a?(String) }).to eq(true)
    end
  end
end

test("configured? is false when the executable is missing") do
  AiTestSupport.with_tmpdir do |root|
    bin = AiTestSupport.make_bin(root, %w[claude]) # codex + muse absent
    AiTestSupport.with_env("PATH" => bin) do
      config = AiTestSupport.make_config(root, bin: bin)
      registry = Ai::Registry.new(config: config)
      expect(registry.configured?("claude")).to eq(true)
      expect(registry.configured?("codex")).to eq(false)
      expect(registry.configured?("muse")).to eq(false)
    end
  end
end

test("configured? is false when the auth location is missing") do
  AiTestSupport.with_tmpdir do |root|
    bin = AiTestSupport.make_bin(root, %w[codex])
    AiTestSupport.with_env("PATH" => bin) do
      config = AiTestSupport.make_config(
        root, bin: bin,
        codex_home: File.join(root, "homes", "codex-missing")
      )
      registry = Ai::Registry.new(config: config)
      expect(registry.configured?("codex")).to eq(false)
      diagnosis = registry.diagnose("codex")
      expect(diagnosis[:executable_found]).to eq(true)
      expect(diagnosis[:home_present]).to eq(false)
      expect(diagnosis[:configured]).to eq(false)
    end
  end
end

test("diagnose reports paths but never file contents") do
  AiTestSupport.with_tmpdir do |root|
    bin = AiTestSupport.make_bin(root, %w[muse])
    AiTestSupport.with_env("PATH" => bin) do
      config = AiTestSupport.make_config(root, bin: bin)
      File.write(File.join(root, "homes", "muse", "auth.json"), "super-secret-bytes")
      diagnosis = Ai::Registry.new(config: config).diagnose("muse")
      expect(diagnosis[:configured]).to eq(true)
      expect(diagnosis.inspect.include?("super-secret-bytes")).to eq(false)
    end
  end
end

test("unknown provider ids raise UnknownProvider") do
  registry = Ai::Registry.new(config: Ai::Config.new)
  expect { registry.adapter_for("gpt") }.to raise_error(Ai::UnknownProvider)
  expect { registry.configured?("gpt") }.to raise_error(Ai::UnknownProvider)
  expect { registry.diagnose("gpt") }.to raise_error(Ai::UnknownProvider)
end

test("absolute executable paths are honored without PATH lookup") do
  AiTestSupport.with_tmpdir do |root|
    bin = AiTestSupport.make_bin(root, %w[my-codex])
    AiTestSupport.with_env("PATH" => "/nonexistent") do
      config = AiTestSupport.make_config(root, bin: bin, codex_executable: File.join(bin, "my-codex"))
      registry = Ai::Registry.new(config: config)
      expect(registry.configured?("codex")).to eq(true)
      expect(registry.resolve_executable("codex")).to eq(File.join(bin, "my-codex"))
    end
  end
end

test("non-executable files do not count as installed CLIs") do
  AiTestSupport.with_tmpdir do |root|
    bin = File.join(root, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "claude"), "not executable")
    AiTestSupport.with_env("PATH" => bin) do
      config = AiTestSupport.make_config(root, bin: bin)
      expect(Ai::Registry.new(config: config).configured?("claude")).to eq(false)
    end
  end
end
