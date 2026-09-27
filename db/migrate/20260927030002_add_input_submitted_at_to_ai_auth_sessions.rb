# frozen_string_literal: true

class AddInputSubmittedAtToAiAuthSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :ai_auth_sessions, :input_submitted_at, :datetime
  end
end
