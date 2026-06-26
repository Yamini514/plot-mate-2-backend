class App::Services::PlatformFeatures < App::Services::Base
  # Per-venture feature toggles. Stored on clients.settings['features'] so the
  # venture app can gate modules off the same config — no dedicated table. Each
  # entry records who flipped it and when (enabled_by / enabled_at).
  FEATURES = [
    { key: 'maintenance',       label: 'Maintenance Module',  description: 'Preventive maintenance schedules & logs' },
    { key: 'complaints',        label: 'Complaints Module',   description: 'Resident complaint tracking' },
    { key: 'visitors',          label: 'Visitor Module',      description: 'Gate visitor & delivery management' },
    { key: 'facility_booking',  label: 'Facility Booking',    description: 'Amenity reservations' },
    { key: 'marketplace',       label: 'Marketplace',         description: 'Community marketplace' },
    { key: 'vendor_management', label: 'Vendor Management',   description: 'Vendor portal & work orders' }
  ].freeze
  # Core modules a fresh venture has on by default (marketplace is opt-in).
  DEFAULTS = %w[maintenance complaints visitors facility_booking vendor_management].freeze
  KEYS = FEATURES.map { |f| f[:key] }.freeze

  def model = Client

  # Catalogue + every venture's current feature matrix (drives the grid).
  def index
    ventures = Client.order(:name).all
    return_success(
      features: FEATURES,
      ventures: ventures.map { |c| { id: c.id, name: c.name, status: c.status_label,
                                     features: feature_states(c) } }
    )
  end

  def toggle
    c   = venture
    key = params[:feature].to_s
    return_errors!('Unknown feature', 422) unless KEYS.include?(key)
    enabled = [true, 'true', 1, '1'].include?(params[:enabled])
    feats   = (c.settings || {})['features'] || {}
    feats[key] = { 'on' => enabled, 'by' => App.cu.id, 'at' => Time.now }
    c.settings = (c.settings || {}).merge('features' => feats)
    save(c) do
      App::Audit.record('feature.toggle', entity: c, client_id: c.id,
                        summary: "#{enabled ? 'Enabled' : 'Disabled'} '#{key}' for #{c.name}",
                        meta: { feature: key, enabled: enabled })
      return_success(id: c.id, features: feature_states(c))
    end
  end

  def venture(id = rp[:id])
    @venture ||= (Client[id] || return_errors!('Venture not found', 404))
  end

  private

  # Merge the stored toggles over the catalogue defaults so every feature has a
  # definite on/off plus its provenance.
  def feature_states(c)
    stored = (c.settings || {})['features'] || {}
    KEYS.to_h do |key|
      s  = stored[key]
      on = s ? !!s['on'] : DEFAULTS.include?(key)
      [key, { on: on, enabled_by: s && s['by'], enabled_at: s && s['at'] }]
    end
  end
end
