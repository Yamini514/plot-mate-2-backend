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

  def list
    ds = model.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    return_success(ds.all.map(&:as_pos), counts: counts_by_status)
  end

  def get = return_success(item.as_pos)

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
    client = Client.new(name: item.venture_name, email: email, active: true)
    admin  = User.new(full_name: item.requester_name, email: email, role: User::ROLES[:admin],
                      phone_number: item.requester_phone, active: true,
                      avatar_url: params[:avatar_url].presence,
                      extras: { 'title' => 'Venture Admin' })
    admin.password = temp_password

    ok = App.db.transaction do
      raise Sequel::Rollback unless client.save
      admin.client_id = client.id
      raise Sequel::Rollback unless admin.save
      item.set(status: 'approved', client_id: client.id, decided_by: App.cu.id,
               decided_at: Time.now, decision_reason: params[:reason])
      item.save_changes
      true
    end

    return return_success(item.as_pos.merge(temp_password: temp_password)) if ok
    return_errors!('Could not activate the venture. Check that the venture email is unique.', 422)
  end

  def reject
    return_errors!("#{item.code} is already #{item.status}", 422) unless item.pending?
    item.set(status: 'rejected', decided_by: App.cu.id, decided_at: Time.now,
             decision_reason: params[:reason])
    item.save_changes
    return_success(item.as_pos)
  end

  def item(id = rp[:id]) = (@item ||= model[id] || return_errors!('Request not found', 404))

  private

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
