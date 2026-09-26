# frozen_string_literal: true

require "db_helper"

test("GET /up reports healthy") do |http:|
  http.get "/up"

  expect(http.last_response.status).to eq(200)
end

test("GET / renders the foundation landing page") do |http:|
  http.get "/"

  expect(http.last_response.status).to eq(200)
  expect(http.last_response.body.include?("Aiconshell")).to eq(true)
end
