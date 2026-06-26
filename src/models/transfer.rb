class App::Models::Transfer < Sequel::Model
  REASONS  = %w[sale gift inheritance other].freeze
  STATUSES = %w[initiated under_review approved rejected completed cancelled].freeze
  OPEN_STATUSES = %w[initiated under_review].freeze

  def validate
    super
    validates_presence [:client_id, :plot_id, :to_owner_name]
    validates_includes STATUSES, :status if status
  end

  def open? = OPEN_STATUSES.include?(status)

  # Apply the transfer once approved: relink the plot to the new owner, reassign
  # the plot's documents, optionally settle dues, and close it out.
  def complete!(decided_by:)
    plot = App::Models::Plot.where(client_id: client_id, id: plot_id).first
    if plot
      plot.set(owner_name: to_owner_name, email: to_email, phone: to_phone,
               membership: 'verified',
               status: (plot.status == 'available' ? 'booked' : plot.status))
      plot.save_changes
      reassign_documents!(plot)
      settle_dues!(plot) if dues_action == 'clear'
    end
    set(status: 'completed', decided_by: decided_by, decided_at: Time.now)
    save_changes
  end

  # Move plot-scoped documents to the new owner so the vault reflects ownership.
  def reassign_documents!(plot)
    App::Models::Document
      .where(client_id: client_id, plot_no: plot.plot_no)
      .update(owner_name: to_owner_name, owner_user_id: nil)
  rescue StandardError => e
    App.logger.error("transfer reassign_documents! failed: #{e.message}")  # non-fatal
  end

  # Write off the plot's open invoices and zero its balance (carry = default
  # leaves the ledger with the new owner). Also stops any chasing reminders.
  def settle_dues!(plot)
    App::Models::Invoice
      .where(client_id: client_id, plot_id: plot.id, status: App::Models::Invoice::OPEN_STATUSES)
      .each { |inv| inv.update(status: 'cancelled') }
    plot.update(amount_due_paise: 0, payment_status: 'paid')
    App::Models::Reminder
      .where(client_id: client_id, plot_id: plot.id, status: 'scheduled')
      .update(status: 'cancelled', updated_at: Time.now)
  rescue StandardError => e
    App.logger.error("transfer settle_dues! failed: #{e.message}")  # non-fatal
  end

  def reject!(decided_by:, reason: nil)
    set(status: 'rejected', decided_by: decided_by, decided_at: Time.now, notes: reason)
    save_changes
  end

  def as_pos
    { id: id, code: code, plot_id: plot_id,
      from_owner_name: from_owner_name, from_email: from_email, from_phone: from_phone,
      to_owner_name: to_owner_name, to_email: to_email, to_phone: to_phone,
      reason: reason, outstanding_paise: outstanding_paise, docs: docs || [],
      dues_action: dues_action || 'carry',
      status: status, approval_request_id: approval_request_id, notes: notes,
      decided_at: decided_at, created_at: created_at }
  end
end
