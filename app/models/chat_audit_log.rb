# frozen_string_literal: true

# IGSIGN — Immutable audit record for every GCinmyPOCKET exchange.
# Submitter identity is stored as a SHA-256 digest of the submitter slug —
# not the slug itself — so the log cannot be used to impersonate a signer.
# Audit log write failures are swallowed so they never block a chat response.
class ChatAuditLog < ApplicationRecord
  belongs_to :caf_workflow

  validates :submitter_token_digest, presence: true
  validates :question, presence: true
end
