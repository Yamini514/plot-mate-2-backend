class App::Services::Patrols < App::Services::Base
  # Security patrols: schedule → start → checkpoint scans → complete. Audited.
  def model = Patrol

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    return_success(ds.all.map { |p| p.as_pos }, counts: counts)
  end

  def get = return_success(item.as_pos(with_logs: true))

  def create
    obj = model.new(
      client_id: current_client_id, title: params[:title],
      checkpoints: Array(params[:checkpoints]).map(&:to_s).reject(&:empty?),
      status: 'scheduled', assigned_to: params[:assigned_to] || App.cu.id, created_by: App.cu.id
    )
    obj.code ||= "PAT-#{1000 + scoped.count + 1}"
    save(obj) { |p| return_success(p.as_pos) }
  end

  def start
    return_errors!('Patrol already started', 422) unless item.status == 'scheduled'
    item.set(status: 'in_progress', started_at: Time.now)
    save(item) do |p|
      App::Audit.record('patrol.start', entity: p, client_id: current_client_id, summary: "Patrol #{p.code} started")
      return_success(p.as_pos(with_logs: true))
    end
  end

  # Record a checkpoint scan / observation (optionally flagging an issue + photo).
  def checkpoint
    validate!('checkpoint' => App::Validate.presence(params[:checkpoint], label: 'Checkpoint'))
    App::Models::PatrolLog.create(
      patrol_id: item.id, client_id: current_client_id, checkpoint: params[:checkpoint],
      note: params[:note], photo_url: params[:photo_url], issue: !!params[:issue], created_by: App.cu.id
    )
    return_success(item.as_pos(with_logs: true))
  end

  def complete
    item.set(status: 'completed', completed_at: Time.now)
    save(item) do |p|
      App::Audit.record('patrol.complete', entity: p, client_id: current_client_id,
                        summary: "Patrol #{p.code} completed (#{p.patrol_logs_dataset.count} checkpoints)")
      return_success(p.as_pos(with_logs: true))
    end
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Patrol not found', 404))

  private

  def counts
    { all: scoped.count, scheduled: scoped.where(status: 'scheduled').count,
      in_progress: scoped.where(status: 'in_progress').count, completed: scoped.where(status: 'completed').count }
  end
end
