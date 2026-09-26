# frozen_string_literal: true

# Static foundation landing page. Not a domain resource: it only proves the
# app boots, renders ERB/CSS, and keeps CSRF/CSP defaults. /admin is built by
# a later issue.
class HomeController < ApplicationController
  def index
  end
end
