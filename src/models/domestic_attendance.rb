# Table is singular (`domestic_attendance`); override Sequel's auto-pluralisation.
class App::Models::DomesticAttendance < Sequel::Model(:domestic_attendance)
  def as_pos
    { id: id, worker_id: worker_id, entry_at: entry_at, exit_at: exit_at, created_at: created_at }
  end
end
