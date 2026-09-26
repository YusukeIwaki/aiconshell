class HardenOutboundDelivery < ActiveRecord::Migration[8.0]
  def change
    add_column :outbound_actions, :lease_token, :string
    add_column :outbound_actions, :lease_expires_at, :datetime
    add_column :outbound_actions, :request_started_at, :datetime
    add_column :outbound_actions, :next_attempt_at, :datetime
    add_index :outbound_actions, [:status, :next_attempt_at]
    add_index :outbound_actions, :lease_expires_at
  end
end
