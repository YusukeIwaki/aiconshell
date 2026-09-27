# frozen_string_literal: true

# Trusted OAuth binding snapshots for issue #26 workflow integration.
# Secret-free only (connection id, generation, provider, principal,
# tenant/cloud). Tokens never land here. Cursors isolate poll state per
# connection so a replaced/disconnected connection never reuses another
# site's cursor; outbound actions fence enqueue vs delivery so a replaced
# connection never sends as a different principal.
class AddOauthBindingSnapshots < ActiveRecord::Migration[8.0]
  def change
    add_column :integration_cursors, :oauth_binding, :jsonb
    add_column :outbound_actions, :oauth_binding, :jsonb
  end
end
