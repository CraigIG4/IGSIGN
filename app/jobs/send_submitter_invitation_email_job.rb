# frozen_string_literal: true

class SendSubmitterInvitationEmailJob
  include Sidekiq::Job

  # Explicit retry limit: invitation emails are time-sensitive; 5 attempts
  # over ~5 minutes is sufficient.  Beyond that the workflow should be
  # investigated manually rather than hammering the mail server.
  sidekiq_options queue: 'default', retry: 5

  def perform(params = {})
    submitter = Submitter.find(params['submitter_id'])

    return if submitter.completed_at?
    return if submitter.submission.archived_at?
    return if submitter.template&.archived_at?
    return if submitter.submission.source == 'invite' && !Accounts.can_send_emails?(submitter.account, on_events: true)

    unless Accounts.can_send_invitation_emails?(submitter.account)
      Rollbar.warning("Skip email: #{submitter.account.id}") if defined?(Rollbar)

      return
    end

    mail = SubmitterMailer.invitation_email(submitter)

    Submitters::ValidateSending.call(submitter, mail)

    mail.deliver_now!

    SubmissionEvent.create!(submitter:, event_type: 'send_email')

    submitter.sent_at ||= Time.current
    submitter.save!

    # Stamp invited_at on the CafStageSubmitter so ReminderCheckJob can
    # calculate the 2/5/9/14-day escalation ladder from the actual send time.
    # Uses update_all (no callbacks, no reload) — safe to call for non-CAF
    # submitters because the WHERE clause will simply match zero rows.
    CafStageSubmitter
      .joins(:caf_stage)
      .where(submitter_id: submitter.id)
      .where(caf_stages: { status: 'active' })
      .where(invited_at: nil)
      .update_all(invited_at: Time.current)
  end
end
