# frozen_string_literal: true

# Trusted fetch-time OAuth source binding for issue #26 workflow integration
# (follow-up to 20260927050000_add_oauth_binding_snapshots.rb).
#
# Cursors isolate poll state per connection and outbound actions fence
# enqueue vs delivery, but triage re-took the *current* connection when an
# ExternalEvent became a Task and when that Task later replied. A poll under
# connection A followed by a reconnect to B could therefore continue the old
# Task as B. These columns fix the secret-free binding snapshot
# (connection id, generation, provider, principal, tenant/cloud) at fetch
# time: every polled ExternalEvent keeps the binding that fetched it
# (first-observed-wins; later generations never rewrite it), and every Task
# keeps the source binding it was created from. Replies proceed only while
# that stored binding still matches the current connection. Tokens never
# land here.
class AddOauthSourceBindings < ActiveRecord::Migration[8.0]
  def change
    add_column :external_events, :oauth_binding, :jsonb
    add_column :tasks, :oauth_binding, :jsonb
  end
end
