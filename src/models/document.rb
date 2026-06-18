class App::Models::Document < Sequel::Model
  VISIBILITIES = %w[admin owners plot].freeze

  def validate
    super
    validates_presence [:client_id, :name]
    validates_includes VISIBILITIES, :visibility if visibility
  end

  def as_pos
    { id: id, code: code, name: name, category: category, size: size,
      url: url, uploaded_by: uploaded_by, date: date,
      visibility: visibility || 'admin', plot_no: plot_no,
      approved: !!approved, approved_by: approved_by, approved_at: approved_at }
  end
end
