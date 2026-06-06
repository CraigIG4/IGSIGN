# frozen_string_literal: true

class CreateChatAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_audit_logs do |t|
      t.references :caf_workflow, null: false, foreign_key: true
      t.string  :submitter_token_digest, null: false
      t.string  :signer_role
      t.text    :question, null: false
      t.text    :answer
      t.string  :error
      t.timestamps
    end

    add_index :chat_audit_logs, %i[caf_workflow_id created_at]
  end
end
