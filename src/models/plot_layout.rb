class App::Models::PlotLayout < Sequel::Model
  def validate
    super
    validates_presence [:client_id]
  end

  def as_pos
    {
      id: id,
      name: name,
      # The browser renders whichever is present; prefer a hosted URL once S3 is wired.
      image_data: image_url.to_s.empty? ? image_data : nil,
      image_url: image_url,
      active: active,
      updated_at: updated_at
    }
  end
end
