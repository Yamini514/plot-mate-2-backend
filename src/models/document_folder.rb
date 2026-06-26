class App::Models::DocumentFolder < Sequel::Model
  def validate
    super
    validates_presence [:client_id, :name]
  end

  def as_pos
    { id: id, parent_id: parent_id, name: name, created_at: created_at }
  end
end
