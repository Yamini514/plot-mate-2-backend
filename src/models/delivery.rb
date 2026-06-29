class App::Models::Delivery < Sequel::Model
  STATUSES = %w[received waiting delivered].freeze

  def validate
    super
    validates_presence [:client_id]
    validates_includes STATUSES, :status if status
  end

  def handover!
    self.status = 'delivered'
    self.delivered_at = Time.now
    save_changes
  end

  def as_pos
    { id: id, code: code, courier: courier, agent: agent, resident_name: resident_name,
      plot_no: plot_no, received_at: received_at, delivered_at: delivered_at, status: status,
      photo_url: (respond_to?(:photo_url) ? photo_url : nil),
      mobile: (respond_to?(:mobile) ? mobile : nil) }
  end
end
