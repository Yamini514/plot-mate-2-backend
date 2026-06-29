class App::Models::DomesticWorker < Sequel::Model
  one_to_many :attendance, class: 'App::Models::DomesticAttendance', key: :worker_id, order: Sequel.desc(:created_at)

  def validate
    super
    validates_presence [:client_id, :name]
  end

  # The currently-open attendance row (inside, not yet exited), if any.
  def open_attendance
    App::Models::DomesticAttendance.where(worker_id: id, exit_at: nil).order(Sequel.desc(:id)).first
  end

  def as_pos
    last = attendance_dataset.first
    { id: id, code: code, name: name, worker_type: worker_type, phone: phone,
      plot_no: plot_no, photo_url: photo_url, active: active.nil? ? true : active,
      inside: !open_attendance.nil?,
      last_seen: (last&.entry_at || last&.created_at) }
  end
end
