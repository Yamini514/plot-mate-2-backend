class App::Services::Plans < App::Services::Base
  def model = Plan

  def list
    ds = scoped.order(Sequel.desc(:active), Sequel.asc(:name))
    return_success(ds.all.map(&:as_pos))
  end

  def get
    return_success(item.as_pos)
  end

  def create
    obj = model.new(coerced_data)
    obj.client_id = current_client_id
    save(obj) do |p|
      App::Audit.record('charge_head.create', entity: p, client_id: current_client_id,
                        summary: "Created charge head #{p.name}")
      return_success(p.as_pos)
    end
  end

  def update
    item.set_fields(coerced_data, coerced_data.keys)
    save(item) do |p|
      App::Audit.record('charge_head.update', entity: p, client_id: current_client_id,
                        summary: "Updated charge head #{p.name}")
      return_success(p.as_pos)
    end
  end

  def item(id = rp[:id])
    @item ||= scoped[id] || return_errors!('Plan not found', 404)
  end

  private

  # Convert the rupee-denominated inputs from the wire into canonical paise.
  def coerced_data
    @coerced_data ||= begin
      d = data_for(:save)
      if d.key?('amount')
        d['amount_paise'] = (d.delete('amount').to_f * 100).round
      end
      if d.key?('late_fee_amount')
        v = d.delete('late_fee_amount')
        d['late_fee_value'] = d['late_fee_type'] == 'percentage' ? v.to_i : (v.to_f * 100).round
      end
      d
    end
  end

  def self.fields
    { save: %i[name description category amount frequency due_day late_fee_type
               late_fee_amount tax_percent property_types auto_invoice active] }
  end
end
