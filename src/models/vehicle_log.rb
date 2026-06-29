class App::Models::VehicleLog < Sequel::Model
  STATUSES    = %w[inside exited].freeze
  OWNER_KINDS = %w[owner visitor].freeze

  def validate
    super
    validates_presence [:client_id, :vehicle_no]
    validates_includes STATUSES, :status if status
    validates_includes OWNER_KINDS, :owner_kind if owner_kind
  end

  def as_pos
    { id: id, code: code, vehicle_no: vehicle_no, vehicle_type: vehicle_type,
      owner_kind: owner_kind, plot_no: plot_no, driver_name: driver_name, phone: phone,
      parking_slot: parking_slot, status: status, entry_at: entry_at, exit_at: exit_at,
      created_at: created_at }
  end
end
