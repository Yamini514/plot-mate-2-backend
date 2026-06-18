class App::Services::Documents < App::Services::Base
  def model = Document

  def list
    ds = scoped.where(active: true).order(Sequel.desc(:date), Sequel.desc(:id))
    ds = ds.where(category: qs[:category]) if qs[:category].present? && qs[:category] != 'all'

    # Owners only ever see documents an admin has approved and shared with them:
    # either association-wide ("owners") or scoped to their own plot ("plot").
    if member_view?
      pno = App.cu.user_obj.extras&.dig('plot_no')
      vis_cond = Sequel.expr(visibility: 'owners')
      vis_cond |= Sequel.expr(visibility: 'plot', plot_no: pno) if pno.present?
      ds = ds.where(approved: true).where(vis_cond)
    elsif qs[:visibility].present? && qs[:visibility] != 'all'
      ds = ds.where(visibility: qs[:visibility])
    end

    return_success(ds.all.map(&:as_pos))
  end

  def get = return_success(item.as_pos)

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= "DOC-#{scoped.count + 1}"
    obj.uploaded_by ||= App.cu.user_obj.full_name
    obj.uploaded_by_user_id ||= App.cu.id
    obj.date ||= Date.today
    obj.visibility ||= 'admin'
    # Owner-visible docs are auto-approved when the admin sets them so on upload;
    # otherwise they stay pending until explicitly approved.
    obj.approved = !!obj.approved
    stamp_approval(obj) if obj.approved
    save(obj) { |d| return_success(d.as_pos) }
  end

  def update
    data = data_for(:save)
    was_approved = item.approved
    item.set_fields(data, data.keys)
    stamp_approval(item) if item.approved && !was_approved
    item.approved_by = item.approved_at = nil unless item.approved
    save(item) { |d| return_success(d.as_pos) }
  end

  # Toggle an owner-facing approval (admin gate before owners can view).
  def approve
    item.approved = params.key?(:approved) ? !!params[:approved] : true
    if item.approved
      stamp_approval(item)
    else
      item.approved_by = item.approved_at = nil
    end
    save(item) { |d| return_success(d.as_pos) }
  end

  def delete
    item.active = false
    save(item) { return_success(item.as_pos) }
  end

  # Presigned S3 PUT so the browser uploads directly (no large bodies via Roda).
  def presign
    return_errors!('S3 not configured', 503) if ENV['AWS_ACCESS_KEY_ID'].blank?
    bucket = ENV['S3_BUCKET'] || 'plotmate-uploads'
    key = "client-#{current_client_id}/docs/#{App.generate_id}-#{params[:filename]}"
    obj = Aws::S3::Resource.new.bucket(bucket).object(key)
    return_success(upload_url: obj.presigned_url(:put, expires_in: 900),
                   key: key, public_url: obj.public_url)
  rescue => e
    App.logger.error("Presign error: #{e.message}")
    return_errors!("Presign failed: #{e.message}", 502)
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Document not found', 404))

  def self.fields
    { save: %i[name category size file_key url uploaded_by date visibility plot_no approved] }
  end

  private

  # A non-admin caller (member) gets the restricted, approved-only view.
  def member_view?
    u = App.cu.user_obj
    u && !u.admin?
  end

  def stamp_approval(obj)
    obj.approved_by ||= App.cu.user_obj.full_name
    obj.approved_at ||= Time.now
  end
end
