class App::Models::PatrolLog < Sequel::Model
  def as_pos
    { id: id, checkpoint: checkpoint, note: note, photo_url: photo_url,
      issue: !!issue, created_at: created_at }
  end
end
