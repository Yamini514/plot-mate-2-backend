class App::Models::Complaint < Sequel::Model
  STATUSES   = %w[open in_progress resolved closed].freeze
  # Default priorities; the venture's editable list (Settings → Lists) may extend
  # these, so priority is validated for presence, not against a fixed enum.
  PRIORITIES = %w[low medium high critical].freeze
  # Escalation ladder, independent of status (raises urgency/visibility).
  ESCALATION = %w[l1 l2 l3].freeze
  NEXT_ESCALATION = { nil => 'l1', 'l1' => 'l2', 'l2' => 'l3', 'l3' => 'l3' }.freeze

  one_to_many :events, class: 'App::Models::ComplaintEvent', key: :complaint_id, order: :created_at

  def validate
    super
    validates_presence [:client_id, :title]
    validates_includes STATUSES, :status     if status
    # priority is venture-configurable (Settings → Lists) → presence only, no enum
    validates_includes ESCALATION, :escalation_level if escalation_level
  end

  # Contact details for the person who raised the complaint — taken from their
  # linked login if any, otherwise from the plot registry by plot number.
  def raiser_contact
    @raiser_contact ||= begin
      u = raised_by_user_id ? App::Models::User[raised_by_user_id] : nil
      p = plot_no ? App::Models::Plot.where(client_id: client_id, plot_no: plot_no).first : nil
      {
        phone: u&.phone_number || p&.phone,
        email: u&.email || p&.email
      }
    end
  end

  def as_pos(with_events: false)
    base = {
      id: id,
      code: code,
      title: title,
      description: description,
      category: category,
      raised_by: raised_by,
      raised_by_user_id: raised_by_user_id,
      raised_by_phone: raiser_contact[:phone],
      raised_by_email: raiser_contact[:email],
      plot_no: plot_no,
      status: status,
      priority: priority,
      escalation_level: escalation_level,
      escalated_at: escalated_at,
      reopen_count: reopen_count || 0,
      resident_confirmed: resident_confirmed || false,
      resident_confirmed_at: resident_confirmed_at,
      resolved_at: resolved_at,
      closed_at: closed_at,
      attachments: attachments || [],
      assigned_to: assigned_to,
      assigned_phone: assigned_phone,
      assigned_email: assigned_email,
      created_at: created_at,
      updated_at: updated_at
    }
    base[:events] = events.map(&:as_pos) if with_events
    base
  end
end
