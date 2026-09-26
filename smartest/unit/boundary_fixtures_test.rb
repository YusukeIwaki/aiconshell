# frozen_string_literal: true

require "test_helper"
require_relative "../support/boundary_fixtures"

# Unit suite: the strict HTTP boundary fixture behaves like the documented
# transport contract without Rails, database, or network access.
test("endpoints match independently without a global order") do
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_json("GET", "https://api.example.com/a", body: { "n" => 1 })
  transport.expect_json("POST", %r{\Ahttps://api\.example\.com/b\z}, body: { "ok" => true })

  post = transport.request(method: "POST", url: "https://api.example.com/b", body: "x")
  get = transport.request(method: :get, url: "https://api.example.com/a")

  expect(post.json).to eq({ "ok" => true })
  expect(get.json).to eq({ "n" => 1 })
  expect(transport.assert_consumed!).to eq(true)
end

test("same-endpoint replies are finite and consumed in registration order") do
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_json("GET", "https://api.example.com/items", body: { "page" => 1 })
  transport.expect_json("GET", "https://api.example.com/items", body: { "page" => 2 })

  first = transport.request(method: "GET", url: "https://api.example.com/items")
  second = transport.request(method: "GET", url: "https://api.example.com/items")

  expect(first.json).to eq({ "page" => 1 })
  expect(second.json).to eq({ "page" => 2 })
  expect(-> { transport.request(method: "GET", url: "https://api.example.com/items") })
    .to raise_error(BoundaryFixtures::ExpectationError)
end

test("unexpected calls fail but stay verifiable after the error is rescued") do
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_json("GET", "https://api.example.com/ok", body: {})

  rescued = nil
  begin
    transport.request(method: "POST", url: "https://api.example.com/ok?token=s3cr3t",
                      headers: { "Authorization" => "Bearer s3cr3t" }, body: "s3cr3t-body")
  rescue BoundaryFixtures::ExpectationError => e
    rescued = e
  end

  expect(rescued.nil?).to eq(false)
  expect(rescued.message.include?("s3cr3t")).to eq(false)
  expect(rescued.message.include?("Bearer")).to eq(false)
  expect(rescued.message.include?("s3cr3t-body")).to eq(false)
  expect(transport.requests.size).to eq(1)
  expect(transport.unexpected_requests.size).to eq(1)
  expect(transport.requests_to("https://api.example.com/ok?token=s3cr3t", method: "POST").size).to eq(1)
  expect(transport.requests_to(%r{api\.example\.com}).size).to eq(1)
  expect(transport.requests_to("https://api.example.com/ok?token=s3cr3t", method: "GET").size).to eq(0)
  expect(-> { transport.assert_consumed! }).to raise_error(BoundaryFixtures::ExpectationError)
end

test("unconsumed scripts fail verification without leaking scripted values") do
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_json("GET", "https://api.example.com/never?token=s3cr3t", body: { "x" => 1 })
  transport.expect_json("GET", %r{\Ahttps://api\.example\.com/regex\?token=s3cr3t-regex-canary\z}, body: { "y" => 2 })

  rescued = nil
  begin
    transport.assert_consumed!
  rescue BoundaryFixtures::ExpectationError => e
    rescued = e
  end

  expect(rescued.nil?).to eq(false)
  expect(rescued.message.include?("s3cr3t")).to eq(false)
  expect(rescued.message.include?("s3cr3t-regex-canary")).to eq(false)
  expect(rescued.message.include?("unconsumed")).to eq(true)
  expect(rescued.message.include?("<regexp>")).to eq(true)
end

test("recorded requests are immutable snapshots") do
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_json("POST", "https://api.example.com/in", body: {})

  headers = { "X-Trace" => "a", "Nested" => { "k" => "v" } }
  body = { "list" => ["x"] }
  transport.request(method: "POST", url: "https://api.example.com/in", headers: headers, body: body)
  headers["X-Trace"] = "MUTATED"
  headers["Nested"]["k"] = "MUTATED"
  body["list"] << "MUTATED"

  recorded = transport.requests.first
  expect(recorded[:headers]).to eq({ "X-Trace" => "a", "Nested" => { "k" => "v" } })
  expect(recorded[:body]).to eq({ "list" => ["x"] })
  expect(recorded.frozen?).to eq(true)
  expect(recorded[:headers].frozen?).to eq(true)
  expect(transport.assert_consumed!).to eq(true)
end

test("scripted 429 keeps real typed behavior with retry_after") do
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_json("GET", "https://api.example.com/limited",
                        status: 429, body: { "error" => "slow down" },
                        headers: { "Retry-After" => "120" })

  rescued = nil
  begin
    transport.request(method: "GET", url: "https://api.example.com/limited")
  rescue Aiconshell::Plugins::RateLimited => e
    rescued = e
  end

  expect(rescued.nil?).to eq(false)
  expect(rescued.status).to eq(429)
  expect(rescued.retry_after).to eq(120)
  expect(transport.assert_consumed!).to eq(true)
end

test("scripted 401 raises HttpError without rate-limit typing") do
  transport = BoundaryFixtures::HttpTransport.new
  transport.expect_json("GET", "https://api.example.com/secret", status: 401, body: {})

  rescued = nil
  begin
    transport.request(method: "GET", url: "https://api.example.com/secret")
  rescue Aiconshell::Plugins::HttpError => e
    rescued = e
  end

  expect(rescued.nil?).to eq(false)
  expect(rescued.status).to eq(401)
  expect(rescued.instance_of?(Aiconshell::Plugins::RateLimited)).to eq(false)
end

test("explicitly scripted transport errors raise as boundary failures") do
  transport = BoundaryFixtures::HttpTransport.new
  failure = Aiconshell::Plugins::TransportTimeout.new(
    http_method: "GET", url: "https://api.example.com/slow", timeout_kind: "read"
  )
  transport.expect_error("GET", %r{\Ahttps://api\.example\.com/slow}, failure)

  rescued = nil
  begin
    transport.request(method: "GET", url: "https://api.example.com/slow")
  rescue Aiconshell::Plugins::TransportTimeout => e
    rescued = e
  end

  expect(rescued.equal?(failure)).to eq(true)
  expect(transport.assert_consumed!).to eq(true)
end
