class App::Services::PlatformFeatures < App::Services::Base
  # Per-venture feature toggles. The CATALOGUE (what features exist, their
  # default state, and which nav hrefs they gate) lives in the editable
  # platform_features table; each venture's on/off lives on
  # clients.settings['features'] with provenance (by / at).
  def model = App::Models::PlatformFeature

  # ---- shared resolvers (used by Settings + route guards) -------------------
  module Resolver
    module_function

    def catalogue
      App::Models::PlatformFeature.where(active: true).order(:sort, :key).all
    end

    # Is `key` enabled for this client? Falls back to the feature's default_on.
    def enabled?(client, key)
      return true if client.nil?
      stored = (client.settings || {})['features'] || {}
      s = stored[key.to_s]
      return !!s['on'] if s
      f = App::Models::PlatformFeature.where(key: key.to_s).first
      f ? (f.default_on.nil? ? true : f.default_on) : true
    rescue StandardError
      true
    end

    # Admin nav hrefs that should be hidden for this client (features that are OFF).
    def disabled_nav(client)
      catalogue.reject { |f| enabled?(client, f.key) }.flat_map(&:nav_list).uniq
    rescue StandardError
      []
    end

    # { key => bool } enabled map for this client.
    def state_map(client)
      catalogue.to_h { |f| [f.key, enabled?(client, f.key)] }
    rescue StandardError
      {}
    end
  end

  # Catalogue + every venture's current feature matrix (drives the grid).
  def index
    cat = Resolver.catalogue
    ventures = Client.order(:name).all
    return_success(
      features: cat.map(&:as_pos),
      ventures: ventures.map { |c| { id: c.id, name: c.name, status: c.status_label,
                                     features: feature_states(c, cat) } }
    )
  end

  # ---- per-venture toggle ---------------------------------------------------
  def toggle
    c   = venture
    key = params[:feature].to_s
    return_errors!('Unknown feature', 422) unless App::Models::PlatformFeature.where(key: key).count.positive?
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

  # ---- catalogue CRUD (super-admin manages the feature list) ----------------
  def create_feature
    key = params[:key].to_s.strip.downcase.gsub(/[^a-z0-9_]/, '_')
    return_errors!('Key is required', 422) if key.empty?
    return_errors!('A feature with that key already exists', 422) if App::Models::PlatformFeature.where(key: key).count.positive?
    f = App::Models::PlatformFeature.new(
      key: key, label: params[:label], description: params[:description],
      default_on: bool(params[:default_on], true), nav_hrefs: nav_param,
      active: true, sort: (App::Models::PlatformFeature.max(:sort).to_i + 1)
    )
    save(f) do |row|
      App::Audit.record('feature.catalogue.create', entity: row, summary: "Added feature '#{row.key}'")
      return_success(row.as_pos)
    end
  end

  def update_feature
    f = feature
    f.set(label: params[:label]) if params.key?(:label)
    f.set(description: params[:description]) if params.key?(:description)
    f.default_on = bool(params[:default_on], f.default_on) if params.key?(:default_on)
    f.active     = bool(params[:active], f.active) if params.key?(:active)
    f.nav_hrefs  = nav_param if params.key?(:nav_hrefs)
    save(f) do |row|
      App::Audit.record('feature.catalogue.update', entity: row, summary: "Updated feature '#{row.key}'")
      return_success(row.as_pos)
    end
  end

  def delete_feature
    f = feature
    key = f.key
    f.destroy
    App::Audit.record('feature.catalogue.delete', entity_type: 'PlatformFeature', summary: "Removed feature '#{key}'")
    return_success(id: f.id)
  end

  def venture(id = rp[:id])
    @venture ||= (Client[id] || return_errors!('Venture not found', 404))
  end

  def feature(id = rp[:id])
    @feature ||= (App::Models::PlatformFeature[id] || return_errors!('Feature not found', 404))
  end

  private

  def bool(v, default)
    return default if v.nil?
    [true, 'true', 1, '1'].include?(v)
  end

  def nav_param
    Array(params[:nav_hrefs]).map { |h| h.to_s.strip }.reject(&:empty?).to_json
  end

  # Merge the stored toggles over each catalogue feature's default so every
  # feature has a definite on/off plus its provenance.
  def feature_states(c, cat = nil)
    cat ||= Resolver.catalogue
    stored = (c.settings || {})['features'] || {}
    cat.to_h do |f|
      s  = stored[f.key]
      on = s ? !!s['on'] : (f.default_on.nil? ? true : f.default_on)
      [f.key, { on: on, enabled_by: s && s['by'], enabled_at: s && s['at'] }]
    end
  end
end
