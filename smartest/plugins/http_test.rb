# frozen_string_literal: true

require_relative "plugins_test_helper"

Http = Aiconshell::Plugins::Http
Plugins = Aiconshell::Plugins

test("Retry-After parses delay seconds, HTTP dates, and garbage") do |clock:|
  expect(Http.parse_retry_after("120", clock: clock)).to eq(120)
  expect(Http.parse_retry_after(nil, clock: clock)).to eq(nil)
  expect(Http.parse_retry_after("", clock: clock)).to eq(nil)
  expect(Http.parse_retry_after("not-a-date", clock: clock)).to eq(nil)

  future = (clock.now + 45).httpdate
  expect(Http.parse_retry_after(future, clock: clock)).to eq(45)

  past = (clock.now - 10).httpdate
  expect(Http.parse_retry_after(past, clock: clock)).to eq(0)
end

test("sanitize_url strips query and fragment, tolerates garbage") do
  expect(Http.sanitize_url("https://example.test/a/b?token=x#frag"))
    .to eq("https://example.test/a/b")
  expect(Http.sanitize_url("https://example.test:8443/a?x=1")).to eq("https://example.test:8443/a")
  expect(Http.sanitize_url("::not a url::")).to eq("(invalid url)")
end

test("next_link extracts rel=next from Link headers") do
  headers = { "link" => '<https://api.test/p2>; rel="next", <https://api.test/p5>; rel="last"' }
  expect(Http.next_link(headers)).to eq("https://api.test/p2")
  expect(Http.next_link({ "link" => '<https://api.test/p1>; rel="prev"' })).to eq(nil)
  expect(Http.next_link({})).to eq(nil)
end

test("check_host! allows listed hosts, rejects anything else") do
  uri = Http.check_host!("https://API.github.com/repos/o/r", ["api.github.com"])
  expect(uri.host.downcase).to eq("api.github.com")

  expect do
    Http.check_host!("https://evil.test/steal", ["api.github.com"])
  end.to raise_error(Plugins::HostRejected, /evil\.test/)

  expect do
    Http.check_host!("::not a url::", ["api.github.com"])
  end.to raise_error(Plugins::HostRejected)
end

test("raise_for_status! maps HTTP failures to typed errors") do |clock:|
  ok = Http::Response.new(status: 200, headers: {}, body: "{}")
  expect(Http.raise_for_status!("GET", "https://a.test/x", ok, clock: clock)).to eq(ok)

  not_found = Http::Response.new(status: 404, headers: {}, body: "nope")
  expect do
    Http.raise_for_status!("GET", "https://a.test/x?secret=1", not_found, clock: clock)
  end.to raise_error(Plugins::HttpError, %r{HTTP 404 from GET https://a\.test/x$})

  limited = Http::Response.new(status: 429, headers: { "retry-after" => "30" }, body: "")
  begin
    Http.raise_for_status!("GET", "https://a.test/x", limited, clock: clock)
    raise "expected RateLimited"
  rescue Plugins::RateLimited => e
    expect(e.retry_after).to eq(30)
    expect(e.message).to match(/retry after 30s/)
  end

  exhausted = Http::Response.new(status: 403, headers: { "x-ratelimit-remaining" => "0" }, body: "")
  expect do
    Http.raise_for_status!("GET", "https://a.test/x", exhausted, clock: clock)
  end.to raise_error(Plugins::RateLimited)

  forbidden = Http::Response.new(status: 403, headers: {}, body: "")
  expect do
    Http.raise_for_status!("GET", "https://a.test/x", forbidden, clock: clock)
  end.to raise_error(Plugins::HttpError)

  boom = Http::Response.new(status: 500, headers: {}, body: "x" * 100)
  begin
    Http.raise_for_status!("POST", "https://a.test/x", boom, clock: clock)
    raise "expected HttpError"
  rescue Plugins::HttpError => e
    expect(e.message).not_to include("x" * 100)
  end
end

test("NetHttpTransport rejects invalid URLs without network I/O") do
  transport = Http::NetHttpTransport.new(open_timeout: 1, read_timeout: 1)
  expect do
    transport.request(method: "GET", url: "gopher://example.test/x", headers: {}, body: nil)
  end.to raise_error(Plugins::TransportError, /unsupported URL/)
end

test("NetHttpTransport maps connection refused to TransportError") do
  port = free_local_port
  transport = Http::NetHttpTransport.new(open_timeout: 1, read_timeout: 1)
  expect do
    transport.request(method: "GET", url: "http://127.0.0.1:#{port}/x", headers: {}, body: nil)
  end.to raise_error(Plugins::TransportError, %r{127\.0\.0\.1})
end

test("NetHttpTransport maps read timeouts to TransportTimeout") do
  server = TCPServer.new("127.0.0.1", 0)
  port = server.addr[1]
  accepted = Queue.new
  worker = Thread.new do
    client = server.accept
    accepted << true
    sleep 5 # never respond; client must time out
    client.close
  rescue StandardError
    nil
  end
  begin
    transport = Http::NetHttpTransport.new(open_timeout: 2, read_timeout: 0.2)
    expect do
      transport.request(method: "GET", url: "http://127.0.0.1:#{port}/slow",
                        headers: {}, body: nil)
    end.to raise_error(Plugins::TransportTimeout, /read timeout/)
    accepted.pop
  ensure
    worker.kill
    server.close
  end
end

test("NetHttpTransport performs a real loopback request") do
  server = TCPServer.new("127.0.0.1", 0)
  port = server.addr[1]
  worker = Thread.new do
    client = server.accept
    client.gets("\r\n\r\n")
    payload = '{"ok":true}'
    client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
    client.close
  rescue StandardError
    nil
  end
  begin
    transport = Http::NetHttpTransport.new(open_timeout: 2, read_timeout: 2)
    response = transport.request(method: "GET", url: "http://127.0.0.1:#{port}/health",
                                 headers: { "Accept" => "application/json" }, body: nil)
    expect(response.status).to eq(200)
    expect(response.json).to eq({ "ok" => true })
  ensure
    worker.join(5)
    server.close
  end
end

def free_local_port
  server = TCPServer.new("127.0.0.1", 0)
  port = server.addr[1]
  server.close
  port
end
