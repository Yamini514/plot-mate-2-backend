class App::Models::Project < Sequel::Model
  one_to_many :project_updates, key: :project_id, order: Sequel.desc(:created_at)
  one_to_many :project_milestones, key: :project_id,
              order: [Sequel.asc(:sort_order), Sequel.asc(:due_on), Sequel.asc(:id)]

  STATUSES = %w[planned active on_hold delayed completed cancelled].freeze
  OPEN_STATUSES = %w[planned active on_hold delayed].freeze

  def validate
    super
    validates_presence [:client_id, :name]
    validates_includes STATUSES, :status if status
  end

  def open? = OPEN_STATUSES.include?(status)

  # Over budget, or past the target date while still open.
  def health
    return 'over_budget' if budget_paise.to_i.positive? && spent_paise.to_i > budget_paise.to_i
    return 'delayed' if status == 'delayed' || (target_date && target_date < Date.today && open?)
    'on_track'
  end

  def as_pos(with_updates: false)
    base = {
      id: id, code: code, name: name, description: description,
      budget: (budget_paise || 0) / 100, spent: (spent_paise || 0) / 100,
      status: status, progress_percent: progress_percent || 0,
      start_date: start_date, target_date: target_date, completed_on: completed_on,
      vendor_staff_id: vendor_staff_id, vendor_name: vendor_name,
      affected_areas: (affected_areas || []), affected_plots: (affected_plots || []),
      health: health, created_at: created_at
    }
    base[:updates] = project_updates.map(&:as_pos) if with_updates
    base
  end
end
