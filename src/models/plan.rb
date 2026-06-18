class App::Models::Plan < Sequel::Model
  FREQUENCIES     = %w[monthly quarterly half_yearly yearly one_time].freeze
  LATE_FEE_TYPES  = %w[fixed percentage].freeze

  def validate
    super
    validates_presence [:name, :client_id]
    validates_includes FREQUENCIES, :frequency        if frequency
    validates_includes LATE_FEE_TYPES, :late_fee_type  if late_fee_type
  end

  # Late fee owed on a given base amount (paise), per this plan's rule.
  def late_fee_for(base_paise)
    if late_fee_type == 'percentage'
      (base_paise * (late_fee_value || 0)) / 100
    else
      late_fee_value || 0 # already paise
    end
  end

  def as_pos
    {
      id: id,
      name: name,
      description: description,
      amount: (amount_paise || 0) / 100,
      frequency: frequency,
      due_day: due_day,
      late_fee_type: late_fee_type,
      # fixed → rupees, percentage → percent
      late_fee_amount: late_fee_type == 'percentage' ? late_fee_value : (late_fee_value || 0) / 100,
      tax_percent: tax_percent,
      property_types: property_types || [],
      auto_invoice: auto_invoice,
      active: active,
      subscribers: subscribers_count
    }
  end

  # No subscriptions table yet: a plan applies to every active plot whose
  # type it targets. For a plot-only association that's all active plots.
  def subscribers_count
    return 0 unless (property_types || []).include?('Plot')
    App::Models::Plot.where(client_id: client_id, active: true).count
  end
end
