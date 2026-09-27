# frozen_string_literal: true

require "securerandom"

# Stable per-browser binding for OAuth attempts (issue #23).
#
# CookieStore only assigns session.id after the session has been written,
# so a first-contact POST would bind its attempt to "". Instead both the
# admin begin/disconnect actions and the public callback keep an explicit
# random token in the session: created on first use, stable afterwards,
# invalidated with the session. The foundation stores only its digest and
# never the raw value.
module OauthBrowserSession
  extend ActiveSupport::Concern

  private

  def oauth_browser_session_id
    token = session[:oauth_browser_id]
    unless token.is_a?(String) && token.bytesize >= 32
      token = SecureRandom.hex(32)
      session[:oauth_browser_id] = token
    end
    token
  end
end
