class App::Models::PlatformFeature < Sequel::Model
  def validate
    super
    validates_presence [:key, :label]
  end

  def nav_list
    v = nav_hrefs
    v = JSON.parse(v) if v.is_a?(String)
    Array(v).map(&:to_s)
  rescue StandardError
    []
  end

  def as_pos
    { id: id, key: key, label: label, description: description,
      default_on: default_on.nil? ? true : default_on, nav_hrefs: nav_list,
      active: active.nil? ? true : active, sort: sort }
  end
end
