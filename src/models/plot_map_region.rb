class App::Models::PlotMapRegion < Sequel::Model
  def validate
    super
    validates_presence [:client_id, :layout_id]
    # Only clickable plot regions need a plot_id; label regions (roads/parks/
    # open spaces) carry text instead and have none.
    validates_presence :plot_id if plot_kind?
  end

  def plot_kind?
    kind.nil? || kind == 'plot'
  end

  # Parsed polygon vertices, or nil for a plain rectangle. Stored as a JSON
  # string (see migration 0033) so it survives multi_insert without pg_json
  # casting; tolerate malformed/legacy values by falling back to nil.
  def points_array
    return nil if points.to_s.empty?
    parsed = JSON.parse(points)
    parsed.is_a?(Array) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  def as_pos
    {
      id: id,
      plot_id: plot_id,
      kind: kind || 'plot',
      # Bounding box — also the rectangle geometry the legacy editor uses.
      x: x,
      y: y,
      w: w,
      h: h,
      points: points_array,
      label: label,
      label_type: label_type
    }
  end
end
