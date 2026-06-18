class App::Models::Complaint < Sequel::Model
  STATUSES   = %w[open in_progress resolved closed].freeze
  PRIORITIES = %w[low medium high].freeze

  def validate
    super
    validates_presence [:client_id, :title]
    validates_includes STATUSES, :status     if status
    validates_includes PRIORITIES, :priority  if priority
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

  def as_pos
    {
      id: id,
      code: code,
      title: title,
      description: description,
      category: category,
      raised_by: raised_by,
      raised_by_phone: raiser_contact[:phone],
      raised_by_email: raiser_contact[:email],
      plot_no: plot_no,
      status: status,
      priority: priority,
      assigned_to: assigned_to,
      assigned_phone: assigned_phone,
      assigned_email: assigned_email,
      created_at: created_at,
      updated_at: updated_at
    }
  end
end
