class App::Models::Document < Sequel::Model
  VISIBILITIES = %w[admin owners plot].freeze

  def validate
    super
    validates_presence [:client_id, :name]
    validates_includes VISIBILITIES, :visibility if visibility
  end

  # Expiry status for the vault view: expired / expiring (≤30d) / ok / none.
  def expiry_state
    return 'none' unless expiry_date
    today = Date.today
    if expiry_date < today then 'expired'
    elsif (expiry_date - today) <= 30 then 'expiring'
    else 'ok'
    end
  end

  def as_pos
    { id: id, code: code, name: name, category: category, size: size,
      url: url, uploaded_by: uploaded_by, date: date,
      visibility: visibility || 'admin', plot_no: plot_no,
      approved: !!approved, approved_by: approved_by, approved_at: approved_at,
      # vault fields (migration 0054)
      doc_type: doc_type, expiry_date: expiry_date, expiry_state: expiry_state,
      owner_user_id: owner_user_id, owner_name: owner_name,
      # folders + versioning (migration 0067)
      folder_id: (respond_to?(:folder_id) ? folder_id : nil),
      version: (respond_to?(:version) ? (version || 1) : 1),
      superseded: (respond_to?(:superseded) ? !!superseded : false) }
  end
end
