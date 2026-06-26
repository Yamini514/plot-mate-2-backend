class App::Models::WorkOrderMaterial < Sequel::Model
  def line_total_paise = (quantity || 1) * (unit_cost_paise || 0)

  def as_pos
    { id: id, item: item, quantity: quantity || 1,
      unit_cost: (unit_cost_paise || 0) / 100, line_total: line_total_paise / 100 }
  end
end
