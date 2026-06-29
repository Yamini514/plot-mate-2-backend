class App::Services::Documents < App::Services::Base
  def model = Document

  def list
    ds = scoped.where(active: true).order(Sequel.desc(:date), Sequel.desc(:id))
    ds = ds.where(category: qs[:category]) if qs[:category].present? && qs[:category] != 'all'
    # Hide superseded versions by default (the version history shows them).
    ds = ds.exclude(superseded: true) unless qs[:include_superseded] == 'true'
    ds = ds.where(folder_id: (qs[:folder_id] == 'root' ? nil : qs[:folder_id].to_i)) if qs[:folder_id].present?

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

  # Documents expiring within N days (default 30) or already expired — drives
  # the vault's renewal reminders. Admin view.
  def expiring
    days   = (qs[:days] || 30).to_i
    cutoff = Date.today + days
    rows = scoped.where(active: true).exclude(expiry_date: nil)
                 .where { expiry_date <= cutoff }
                 .order(:expiry_date).all
    return_success(rows.map(&:as_pos))
  end

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

  # Owner uploads a document for their own plot. Always lands pending admin
  # approval, scoped to the uploader's plot, with the owner recorded.
  def member_create
    u = App.cu.user_obj
    obj = model.new(
      client_id: current_client_id,
      name: params[:name], category: params[:category].presence || 'Other',
      url: params[:url], size: params[:size],
      doc_type: params[:doc_type], visibility: 'plot',
      plot_no: u.extras&.dig('plot_no'),
      owner_user_id: u.id, owner_name: u.full_name,
      uploaded_by: u.full_name, uploaded_by_user_id: u.id,
      date: Date.today, approved: false
    )
    obj.code ||= "DOC-#{scoped.count + 1}"
    save(obj) do |d|
      App::Audit.record('document.upload', entity: d, client_id: d.client_id,
                        summary: "#{u.full_name} uploaded #{d.name} (pending review)")
      return_success(d.as_pos)
    end
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

  # Presigned S3 PUT so the browser uploads any document type directly (no large
  # bodies through Roda). The bucket is private, so the client stores our
  # /uploads/view proxy (keyed by `key`) and reads back through a short-lived
  # presigned GET — see Uploads#presigned_view_url. Mirrors Uploads#presign but
  # for arbitrary file types under the document/ prefix.
  def presign
    return_errors!('S3 not configured', 503) unless s3_configured?

    content_type = params[:content_type].to_s
    content_type = 'application/octet-stream' if content_type.empty?
    ext = File.extname(params[:filename].to_s).downcase.gsub(/[^a-z0-9.]/, '')

    bucket = ENV['AWS_S3_BUCKET']
    key    = "document/#{current_client_id}/#{SecureRandom.uuid}#{ext}"

    require 'aws-sdk-s3'
    signer = Aws::S3::Presigner.new(client: s3_client)
    upload_url = signer.presigned_url(
      :put_object, bucket: bucket, key: key,
      content_type: content_type, expires_in: 900
    )
    return_success(upload_url: upload_url, key: key)
  rescue => e
    App.logger.error("Presign error: #{e.class}: #{e.message}")
    return_errors!("Presign failed: #{e.message}", 502)
  end

  # Upload a new version of an existing document: clone the row with the new
  # file, bump the version, link the chain, and hide the prior from the list.
  def new_version
    prev = item
    validate!('url' => App::Validate.presence(params[:url], label: 'File'))
    obj = model.new(
      client_id: current_client_id, name: prev.name, category: prev.category,
      url: params[:url], size: params[:size], doc_type: prev.doc_type,
      visibility: prev.visibility, plot_no: prev.plot_no, folder_id: prev.folder_id,
      expiry_date: params[:expiry_date].presence || prev.expiry_date,
      owner_user_id: prev.owner_user_id, owner_name: prev.owner_name,
      uploaded_by: App.cu.user_obj.full_name, uploaded_by_user_id: App.cu.id,
      date: Date.today, approved: prev.approved,
      version: (prev.version || 1) + 1, supersedes_id: prev.id
    )
    obj.code ||= "DOC-#{scoped.count + 1}"
    stamp_approval(obj) if obj.approved
    save(obj) do |d|
      prev.update(superseded: true)
      App::Audit.record('document.version', entity: d, client_id: current_client_id,
                        summary: "New version (v#{d.version}) of #{d.name}")
      return_success(d.as_pos)
    end
  end

  # Vendor's own compliance documents (license/insurance/certification).
  def vendor_list
    rows = scoped.where(active: true, owner_user_id: App.cu.id)
                 .exclude(superseded: true).order(Sequel.desc(:date)).all
    return_success(rows.map(&:as_pos))
  end

  # Vendor uploads a compliance document → lands pending admin verification.
  def vendor_upload
    validate!('name' => App::Validate.text(params[:name], min: 1, max: 160, label: 'Name'),
              'url'  => App::Validate.presence(params[:url], label: 'File'))
    u = App.cu.user_obj
    obj = model.new(
      client_id: current_client_id, name: params[:name], url: params[:url], size: params[:size],
      category: params[:category].presence || 'Compliance',
      doc_type: params[:doc_type].presence || 'other',
      expiry_date: params[:expiry_date].presence, visibility: 'admin',
      owner_user_id: u.id, owner_name: u.full_name,
      uploaded_by: u.full_name, uploaded_by_user_id: u.id, date: Date.today, approved: false
    )
    obj.code ||= "DOC-#{scoped.count + 1}"
    save(obj) do |d|
      App::Audit.record('document.upload', entity: d, client_id: d.client_id,
                        summary: "#{u.full_name} uploaded #{d.name} (pending verification)")
      return_success(d.as_pos)
    end
  end

  # Owner replaces (uploads a new version of) their OWN document. Ownership-gated
  # then reuses the same version-chain logic; the new version lands pending review.
  def member_new_version
    prev = scoped[rp[:id]] || return_errors!('Document not found', 404)
    return_errors!('You can only replace your own documents', 403) unless prev.owner_user_id == App.cu.id
    @item = prev
    new_version
  end

  # Version history for a document (the chain by supersedes_id).
  def versions
    chain = []
    cur = item
    chain << cur
    while cur&.supersedes_id
      cur = scoped[cur.supersedes_id]
      chain << cur if cur
    end
    return_success(chain.compact.map(&:as_pos))
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Document not found', 404))

  def self.fields
    { save: %i[name category size file_key url uploaded_by date visibility plot_no approved
               doc_type expiry_date owner_user_id owner_name folder_id] }
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
