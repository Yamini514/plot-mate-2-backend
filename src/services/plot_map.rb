class App::Services::PlotMap < App::Services::Base
  def model = PlotLayout

  # GET /admin/plot-map — the active layout (if any) plus its clickable regions.
  def show
    layout = active_layout
    regions = layout ? region_scope.where(layout_id: layout.id, active: true).order(:id).all : []
    return_success(layout: layout&.as_pos, regions: regions.map(&:as_pos))
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

  # PUT /admin/plot-map/regions — replace the full set of rectangles in one shot.
  # Body: { regions: [{ plot_id, x, y, w, h }, ...] }
  def save_regions
    layout = active_layout
    return_errors!('Import a layout before mapping plots', 400) unless layout

    valid_ids = Plot.where(client_id: current_client_id, active: true).select_map(:id)
    rows = Array(params && params[:regions]).filter_map do |reg|
      pid = reg[:plot_id].to_i
      next unless valid_ids.include?(pid)
      {
        client_id: current_client_id,
        layout_id: layout.id,
        plot_id:   pid,
        x: clamp_pct(reg[:x]), y: clamp_pct(reg[:y]),
        w: clamp_pct(reg[:w]), h: clamp_pct(reg[:h]),
        active: true,
        created_at: Time.now, updated_at: Time.now
      }
    end

    App.db.transaction do
      region_scope.where(layout_id: layout.id).delete
      App.db[:plot_map_regions].multi_insert(rows) if rows.any?
    end
    return_success(region_scope.where(layout_id: layout.id, active: true).order(:id).all.map(&:as_pos))
  end

  private

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
