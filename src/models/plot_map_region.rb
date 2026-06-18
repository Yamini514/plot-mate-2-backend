class App::Models::PlotMapRegion < Sequel::Model
  def validate
    super
    validates_presence [:client_id, :layout_id, :plot_id]
  end

  def as_pos
    {
      id: id,
      plot_id: plot_id,
      x: x,
      y: y,
      w: w,
      h: h
    }
  end
end
