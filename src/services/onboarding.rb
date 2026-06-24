class App::Services::Onboarding < App::Services::Base
  def model = App::Models::OnboardingRequest

  # Public — a prospective venture submits an onboarding request. No tenant
  # scope: a request exists before any workspace does.
  def submit
    obj = model.new(data_for(:submit))
    obj.status = 'submitted'
    obj.code ||= "REQ-#{1001 + model.count}"
    save(obj) { |o| return_success(o.as_pos) }
  end

  # Public — attach a document to a request mid-intake (keyed by the request's
  # human code so the prospect needs no account). Reuses the Uploads presign
  # flow on the client; here we just persist the resulting URL/key.
  def attach_document
    req = model.where(code: rp[:code]).first || return_errors!('Request not found', 404)
    doc = App::Models::OnboardingDocument.new(
      onboarding_request_id: req.id,
      doc_type: params[:doc_type].presence || 'other',
      name:     params[:name],
      url:      params[:url],
      file_key: params[:file_key],
      size:     params[:size],
      status:   'pending'
    )
    doc.code ||= "ODOC-#{1001 + App::Models::OnboardingDocument.count}"
    save(doc) { |d| return_success(d.as_pos) }
  end

  def list
    ds = model.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    return_success(ds.all.map { |o| o.as_pos }, counts: counts_by_status)
  end

  def get = return_success(item.as_pos(with_documents: true))

  def documents = return_success(item.onboarding_documents.map(&:as_pos))

  # Verify / reject a single uploaded document during review.
  def verify_document
    doc = App::Models::OnboardingDocument.where(id: rp[:doc], onboarding_request_id: item.id).first
    return_errors!('Document not found', 404) unless doc
    status = params[:status].to_s == 'rejected' ? 'rejected' : 'verified'
    doc.set(status: status, review_note: params[:review_note],
            reviewed_by: App.cu.id, reviewed_at: Time.now)
    save(doc) { return_success(doc.as_pos) }
  end

  # Ask the requester to amend their submission before a decision. Stays
  # actionable (pending? is true for changes_requested).
  def request_changes
    return_errors!("#{item.code} is already #{item.status}", 422) unless item.pending?
    item.set(status: 'changes_requested', decision_reason: params[:reason])
    item.save_changes
    App::Audit.record('onboarding.request_changes', entity: item,
                      summary: "Requested changes on #{item.code}", meta: { reason: params[:reason] })
    return_success(item.as_pos)
  end

  # Super-admin approval: provisions the venture (client) and its first Venture
  # Admin login in one transaction, then marks the request approved. The
  # one-time temporary password is returned once so the super admin can pass it
  # to the new admin (who can then reset it via the normal flow). Saves are
  # checked explicitly (raise_on_save_failure is off) so a failure rolls the
  # whole thing back rather than leaving a half-provisioned venture.
  def approve
    return_errors!("#{item.code} is already #{item.status}", 422) unless item.pending?

    email = item.requester_email.to_s.strip.downcase
    if User.where(email: email, active: true).first
      return_errors!('A user with this email already exists — cannot create a Venture Admin login.', 422)
    end

    temp_password = SecureRandom.alphanumeric(10)
    client = Client.new(name: item.venture_name, email: email, active: true,
                        status: 'active', approved_at: Time.now, approved_by: App.cu.id,
                        onboarding_request_id: item.id)
    admin  = User.new(full_name: item.requester_name, email: email, role: User::ROLES[:admin],
                      phone_number: item.requester_phone, active: true,
                      avatar_url: params[:avatar_url].presence,
                      extras: { 'title' => 'Venture Admin' })
    admin.password = temp_password

    ok = App.db.transaction do
      raise Sequel::Rollback unless client.save
      admin.client_id = client.id
      raise Sequel::Rollback unless admin.save
      seed_layout!(client)
      item.set(status: 'approved', client_id: client.id, decided_by: App.cu.id,
               decided_at: Time.now, decision_reason: params[:reason])
      item.save_changes
      true
    end

    if ok
      App::Audit.record('venture.approve', entity: client, client_id: client.id,
                        summary: "Approved #{item.code} → activated #{client.name}",
                        meta: { onboarding_request_id: item.id, admin_email: email })
      return return_success(item.as_pos.merge(temp_password: temp_password))
    end
    return_errors!('Could not activate the venture. Check that the venture email is unique.', 422)
  end

  def reject
    return_errors!("#{item.code} is already #{item.status}", 422) unless item.pending?
    item.set(status: 'rejected', decided_by: App.cu.id, decided_at: Time.now,
             decision_reason: params[:reason])
    item.save_changes
    App::Audit.record('venture.reject', entity: item,
                      summary: "Rejected #{item.code}", meta: { reason: params[:reason] })
    return_success(item.as_pos)
  end

  def item(id = rp[:id]) = (@item ||= model[id] || return_errors!('Request not found', 404))

  private

  # If a layout/map was uploaded with the request, seed the new venture's
  # PlotLayout so the Venture Admin opens to their map already in place.
  def seed_layout!(client)
    map = item.onboarding_documents_dataset.where(doc_type: 'layout_map').first
    return unless map && map.url.present?
    App::Models::PlotLayout.create(client_id: client.id, name: 'Master plan',
                                   image_url: map.url, active: true)
  rescue => e
    App.logger.error("seed_layout! failed: #{e.message}")  # non-fatal
  end

  def counts_by_status
    c = model.group_and_count(:status).all
             .each_with_object({}) { |r, h| h[r[:status]] = r[:count] }
    c['all'] = model.count
    c
  end

  def self.fields
    { submit: %i[venture_name location description requester_name requester_email
                 requester_phone plot_count notes] }
  end
end
