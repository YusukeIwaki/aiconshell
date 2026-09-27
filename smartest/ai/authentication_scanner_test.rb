# frozen_string_literal: true

require_relative "authentication_support"

Auth = Aiconshell::Ai::Authentication unless defined?(Auth)
Support = AuthenticationTestSupport unless defined?(Support)

# --- UrlPolicy ---

test("url policy accepts the official verification urls with query intact") do
  expect(Auth::UrlPolicy.validate("claude", Support::CLAUDE_URL)).to eq(Support::CLAUDE_URL)
  expect(Auth::UrlPolicy.validate("codex", Support::CODEX_URL)).to eq(Support::CODEX_URL)
  expect(Auth::UrlPolicy.validate("codex", Support::CODEX_URL_WITH_QUERY)).to eq(Support::CODEX_URL_WITH_QUERY)
  expect(Auth::UrlPolicy.validate("muse", Support::MUSE_URL)).to eq(Support::MUSE_URL)
  expect(Auth::UrlPolicy.validate("muse", "https://auth.meta.com/oauth/device/")).to eq("https://auth.meta.com/oauth/device/")
end

test("url policy rejects providers and shapes outside the allowlist") do
  bad = [
    "http://auth.openai.com/codex/device",
    "https://auth.openai.com:8443/codex/device",
    "https://user@auth.openai.com/codex/device",
    "https://user:pass@auth.openai.com/codex/device",
    "https://auth.openai.com.evil.example/codex/device",
    "https://evil-auth.openai.com/codex/device",
    "https://auth.openai.com/codex/device#fragment",
    "https://auth.openai.com/codex/device?x=1#fragment",
    "https://auth.openai.com/codex\\device",
    "https://auth.openai.com/codex/device?x=a b",
    "https://sub.auth.openai.com/codex/device",
    "https://auth.openai.com/CODEX/DEVICE",
    "https://auth.openai.com/codex/device/",
    "https://auth.openai.com/codex/device2",
    "",
    "not a url",
    "ftp://auth.openai.com/codex/device"
  ]
  bad.each do |candidate|
    expect(Auth::UrlPolicy.validate("codex", candidate)).to be_nil
  end
  expect(Auth::UrlPolicy.validate("codex", "https://auth.openai.com/codex/device?x=\x01y")).to be_nil
  expect(Auth::UrlPolicy.validate("codex", "https://auth.openai.com/codex/device?x=日本語")).to be_nil
  expect(Auth::UrlPolicy.validate("codex", "http://auth.openai.com/codex/device".upcase)).to be_nil
  # Scheme and host are case-insensitive per RFC 3986; the path stays strict.
  expect(Auth::UrlPolicy.validate("codex", "HTTPS://AUTH.OPENAI.COM/codex/device"))
    .to eq("HTTPS://AUTH.OPENAI.COM/codex/device")
  overlong = "https://auth.openai.com/codex/device?pad=#{"p" * 2048}"
  expect(Auth::UrlPolicy.validate("codex", overlong)).to be_nil
  expect(Auth::UrlPolicy.validate("nope", Support::CODEX_URL)).to be_nil
  expect(Auth::UrlPolicy.validate("codex", nil)).to be_nil
end

test("url policy keeps providers isolated") do
  expect(Auth::UrlPolicy.validate("claude", Support::CODEX_URL)).to be_nil
  expect(Auth::UrlPolicy.validate("codex", Support::CLAUDE_URL)).to be_nil
  expect(Auth::UrlPolicy.validate("muse", Support::CLAUDE_URL)).to be_nil
  expect(Auth::UrlPolicy.validate("claude", "https://claude.com/cai/oauth/authorize")).to eq("https://claude.com/cai/oauth/authorize")
end

# --- Scanner: urls and chunking ---

test("scanner holds a trailing split url until it completes") do
  scanner = Auth::Scanner.new("codex")
  scanner.feed("go to #{Support::CODEX_URL[0, 20]}")
  expect(scanner.challenge).to be_nil
  expect(scanner.foreign_url?).to eq(false)
  scanner.feed("#{Support::CODEX_URL[20..]}\n")
  expect(scanner.challenge["verification_uri"]).to eq(Support::CODEX_URL)
  expect(scanner.foreign_url?).to eq(false)
end

test("scanner finalizes a trailing url only at finish") do
  scanner = Auth::Scanner.new("muse")
  scanner.feed("open #{Support::MUSE_URL}")
  expect(scanner.challenge).to be_nil
  scanner.finish
  expect(scanner.challenge["verification_uri"]).to eq(Support::MUSE_URL)
end

test("scanner flags foreign urls but keeps the first passing url") do
  scanner = Auth::Scanner.new("codex")
  scanner.feed("visit #{Support::CODEX_URL}\n")
  expect(scanner.foreign_url?).to eq(false)
  # A second distinct passing URL is ignored, not fatal.
  scanner.feed("also #{Support::CODEX_URL_WITH_QUERY}\n")
  expect(scanner.foreign_url?).to eq(false)
  expect(scanner.challenge["verification_uri"]).to eq(Support::CODEX_URL)
  scanner.feed("visit https://evil.example/x\n")
  expect(scanner.foreign_url?).to eq(true)
end

test("scanner extracts osc8 hyperlink targets and split escapes") do
  scanner = Auth::Scanner.new("claude")
  scanner.feed("open \e]8;;#{Support::CLAUDE_URL}\e\\link\e]8;;\e\\\n")
  expect(scanner.challenge["verification_uri"]).to eq(Support::CLAUDE_URL)

  split = Auth::Scanner.new("codex")
  split.feed("go \e]8;;#{Support::CODEX_URL[0, 15]}")
  split.feed("#{Support::CODEX_URL[15..]}\e\\here\e]8;;\e\\\n")
  expect(split.challenge["verification_uri"]).to eq(Support::CODEX_URL)
end

test("scanner normalizes carriage returns and strips sgr") do
  scanner = Auth::Scanner.new("codex")
  scanner.feed("progress 50%\r\e[1;32m#{Support::CODEX_URL}\e[0m\r\ncode #{Support::CODEX_CODE}\r\n")
  challenge = scanner.challenge
  expect(challenge["verification_uri"]).to eq(Support::CODEX_URL)
  expect(challenge["user_code"]).to eq(Support::CODEX_CODE)
end

# --- Scanner: codes and prompts ---

test("scanner never mistakes url query values for user codes") do
  scanner = Auth::Scanner.new("muse")
  scanner.feed("open https://auth.meta.com/oauth/device/?code=QUERY-VALUE9\n")
  expect(scanner.challenge["user_code"]).to be_nil
end

test("scanner extracts device codes by provider rules") do
  codex = Auth::Scanner.new("codex")
  codex.feed("Visit #{Support::CODEX_URL}\nEnter code #{Support::CODEX_CODE}\n")
  expect(codex.challenge["user_code"]).to eq(Support::CODEX_CODE)

  hyphenless = Auth::Scanner.new("codex")
  hyphenless.feed("Visit #{Support::CODEX_URL}\nYour code is #{Support::MUSE_CODE}\n")
  expect(hyphenless.challenge["user_code"]).to be_nil

  muse = Auth::Scanner.new("muse")
  muse.feed("Visit #{Support::MUSE_URL}\nYour code is #{Support::MUSE_CODE}\n")
  expect(muse.challenge["user_code"]).to eq(Support::MUSE_CODE)

  plain_word = Auth::Scanner.new("muse")
  plain_word.feed("Visit #{Support::MUSE_URL}\nApprove the code in your browser soon\n")
  expect(plain_word.challenge["user_code"]).to be_nil

  claude = Auth::Scanner.new("claude")
  claude.feed("Visit #{Support::CLAUDE_URL}\nPaste code here if prompted > ")
  expect(claude.challenge["user_code"]).to be_nil
  expect(claude.challenge["input_required"]).to eq(true)
  expect(claude.input_required?).to eq(true)
end

test("scanner input prompt is claude-only") do
  %w[codex muse].each do |provider|
    scanner = Auth::Scanner.new(provider)
    scanner.feed("Paste code here if prompted > ")
    expect(scanner.input_required?).to eq(false)
  end
end

test("scanner counts bytes and detects api-key markers") do
  scanner = Auth::Scanner.new("codex")
  scanner.feed("hello")
  scanner.feed(" world")
  expect(scanner.bytes).to eq(11)
  expect(scanner.api_key_hit?).to eq(false)
  scanner.feed("\nplease run codex login --with-api-key\n")
  expect(scanner.api_key_hit?).to eq(true)
end

test("scanner exit hints distinguish expiry, auth failure and unknown") do
  expired = Auth::Scanner.new("codex")
  expired.feed("the device code expired\n")
  expect(expired.exit_hint).to eq(:expired)

  denied = Auth::Scanner.new("claude")
  denied.feed("Login failed\n")
  expect(denied.exit_hint).to eq(:auth_failed)

  unknown = Auth::Scanner.new("muse")
  unknown.feed("something entirely new\n")
  expect(unknown.exit_hint).to eq(:unknown)
end

# --- Result ---

test("authentication results accept the fixed vocabulary only") do
  %w[connected disconnected unavailable failed cancelled expired].each do |state|
    code = state == "failed" ? "unknown" : nil
    expect(Auth::Result.result(state, code)).to eq({ "state" => state, "error_code" => code })
  end
  Auth::Result::ERROR_CODES.each do |code|
    expect(Auth::Result.result("failed", code)["error_code"]).to eq(code)
  end
  expect { Auth::Result.result("maybe", nil) }.to raise_error(Aiconshell::Ai::InvalidOutput)
  expect { Auth::Result.result("failed", "bogus") }.to raise_error(Aiconshell::Ai::InvalidOutput)
end

test("authentication challenges validate structure and policy") do
  good = Auth::Result.challenge(
    provider: "muse", verification_uri: Support::MUSE_URL,
    user_code: Support::MUSE_CODE, input_required: false
  )
  expect(good).to eq(
    { "verification_uri" => Support::MUSE_URL, "user_code" => Support::MUSE_CODE, "input_required" => false }
  )
  expect(Auth::Result.challenge(
    provider: "muse", verification_uri: "https://evil.example/x",
    user_code: nil, input_required: false
  )).to be_nil
  expect(Auth::Result.challenge(
    provider: "muse", verification_uri: Support::MUSE_URL,
    user_code: "bad\0code", input_required: false
  )).to be_nil
  expect(Auth::Result.challenge(
    provider: "muse", verification_uri: Support::MUSE_URL,
    user_code: "x" * 65, input_required: false
  )).to be_nil
  expect(Auth::Result.challenge(
    provider: "muse", verification_uri: Support::MUSE_URL,
    user_code: nil, input_required: "yes"
  )).to be_nil
end

test("authentication schemas reject extra keys") do
  tampered_result = { "state" => "connected", "error_code" => nil, "token" => "x" }
  expect { Aiconshell::Ai::SchemaValidator.validate!(tampered_result, Auth::Result::RESULT_SCHEMA, provider: "t") }
    .to raise_error(Aiconshell::Ai::InvalidOutput)
  tampered_challenge = {
    "verification_uri" => Support::MUSE_URL, "user_code" => nil,
    "input_required" => false, "secret" => "x"
  }
  expect { Aiconshell::Ai::SchemaValidator.validate!(tampered_challenge, Auth::Result::CHALLENGE_SCHEMA, provider: "t") }
    .to raise_error(Aiconshell::Ai::InvalidOutput)
end
