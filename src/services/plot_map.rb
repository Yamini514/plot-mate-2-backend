class App::Services::PlotMap < App::Services::Base
  def model = PlotLayout

  # GET /admin/plot-map — the active layout (if any) plus its clickable regions.
  def show
    layout = active_layout
    regions = layout ? region_scope.where(layout_id: layout.id, active: true).order(:id).all : []
    return_success(layout: layout&.as_pos, regions: regions.map(&:as_pos))
  end

  # POST /admin/plot-map/detect — read the plot numbers off the uploaded site
  # plan with AI vision, grouped by phase. Returns a draft the admin reviews and
  # corrects before any plots are created (detection is best-effort). Counts are
  # computed here so the UI can show "N plots across M phases" at a glance.
  def detect_plots
    layout = active_layout
    return_errors!('Import a site plan image first.', 400) unless layout

    result = App::Anthropic.detect_plots(image_data: layout.image_data, image_url: layout.image_url)

    # Normalize + de-duplicate within each phase, preserving printed form.
    phases = Array(result['phases']).filter_map do |grp|
      name = grp['phase'].to_s.strip
      name = 'Unphased' if name.empty?
      nums = Array(grp['numbers']).map { |n| n.to_s.strip }.reject(&:empty?).uniq
      next if nums.empty?
      { phase: name, numbers: nums, count: nums.size }
    end

    return_success(phases: phases, total: phases.sum { |p| p[:count] }, mock: App::Anthropic.mock_enabled?)
  rescue => e
    App.logger.error("plot detect failed: #{e.class}: #{e.message}")
    return_errors!(e.message, 422)
  end

  # PUT /admin/plot-map/layout — import (or replace) the site plan image.
  # Body: { name, image_data }  (image_data is a data URL until S3 is configured)
  def save_layout
    img = params && params[:image_data]
    return_errors!('image_data is required', 400) if img.to_s.empty?

    layout = active_layout
    if layout
      layout.set(image_data: img, name: params[:name].presence || layout.name, updated_at: Time.now)
    else
      layout = PlotLayout.new(client_id: current_client_id,
                              image_data: img,
                              name: params[:name].presence || 'Master plan')
    end
    save(layout) { |l| return_success(l.as_pos) }
  end

  # DELETE /admin/plot-map/layout — soft-delete the layout and its regions.
  def remove_layout
    layout = active_layout
    return return_success(removed: false) unless layout

    App.db.transaction do
      region_scope.where(layout_id: layout.id).update(active: false, updated_at: Time.now)
      layout.update(active: false, updated_at: Time.now)
    end
    return_success(removed: true)
  end

  # PUT /admin/plot-map/regions — replace the full set of regions in one shot.
  # Body: { regions: [ region, ... ] } where each region is either
  #   a clickable plot:  { kind: 'plot', plot_id, x, y, w, h, points }
  #   a static label:    { kind: 'label', label, label_type, x, y, w, h, points }
  # `points` is an optional array of [x, y] percentage pairs (a polygon); when
  # present it overrides x/y/w/h, which are recomputed as its bounding box so
  # the legacy rectangle view still renders something sensible. Omitting kind
  # (the old payload) is treated as a plot region — fully backward compatible.
  def save_regions
    layout = active_layout
    return_errors!('Import a layout before mapping plots', 400) unless layout

    valid_ids = Plot.where(client_id: current_client_id, active: true).select_map(:id)
    now = Time.now

    rows = Array(params && params[:regions]).filter_map do |reg|
      kind = reg[:kind].to_s == 'label' ? 'label' : 'plot'
      pts  = sanitize_points(reg[:points])
      box  = pts ? bbox(pts) : { x: reg[:x], y: reg[:y], w: reg[:w], h: reg[:h] }

      # Every row carries the same columns (multi_insert needs a uniform key
      # set); plot vs label just decides which of plot_id / label are filled.
      base = {
        client_id: current_client_id,
        layout_id: layout.id,
        kind: kind,
        plot_id: nil,
        label: nil,
        label_type: nil,
        x: clamp_pct(box[:x]), y: clamp_pct(box[:y]),
        w: clamp_pct(box[:w]), h: clamp_pct(box[:h]),
        points: pts&.to_json,
        active: true,
        created_at: now, updated_at: now
      }

      if kind == 'label'
        label = reg[:label].to_s.strip
        next if label.empty?
        base.merge(label: label, label_type: reg[:label_type].presence)
      else
        pid = reg[:plot_id].to_i
        next unless valid_ids.include?(pid)
        base.merge(plot_id: pid)
      end
    end

    App.db.transaction do
      region_scope.where(layout_id: layout.id).delete
      App.db[:plot_map_regions].multi_insert(rows) if rows.any?
    end
    return_success(region_scope.where(layout_id: layout.id, active: true).order(:id).all.map(&:as_pos))
  end

  private

  # Coerce an incoming polygon into a clean array of [x, y] percentage pairs,
  # or nil if it isn't a usable polygon (need at least a triangle).
  def sanitize_points(raw)
    return nil unless raw.is_a?(Array) && raw.size >= 3
    pts = raw.filter_map do |p|
      x, y = p.is_a?(Array) ? p : [p && p[:x], p && p[:y]]
      next if x.nil? || y.nil?
      [clamp_pct(x), clamp_pct(y)]
    end
    pts.size >= 3 ? pts : nil
  end

  # Axis-aligned bounding box of a polygon, as top-left + size percentages.
  def bbox(pts)
    xs = pts.map { |p| p[0] }
    ys = pts.map { |p| p[1] }
    { x: xs.min, y: ys.min, w: xs.max - xs.min, h: ys.max - ys.min }
  end

  def active_layout
    @active_layout ||= scoped.where(active: true).order(Sequel.desc(:id)).first
  end

  def region_scope
    PlotMapRegion.where(client_id: current_client_id)
  end

  def clamp_pct(v)
    f = v.to_f
    f = 0.0 if f < 0
    f = 100.0 if f > 100
    f.round(3)
  end
end
