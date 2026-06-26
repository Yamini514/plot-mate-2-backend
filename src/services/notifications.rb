class App::Services::Notifications < App::Services::Base
  # The caller's own in-app notifications (Owner Portal). Strictly self-scoped:
  # every query is bound to App.cu.id, so an owner can only ever read/mutate
  # their own notifications (no IDOR).
  def model = Notification

  def list
    ds = Notification.where(user_id: App.cu.id).order(Sequel.desc(:created_at))
    ds = ds.where(read_at: nil) if qs[:unread] == 'true'
    total = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   unread: unread_count, **pagination_meta(total))
  end

  def unread = return_success(count: unread_count)

  def mark_read
    n = own(rp[:id])
    n.update(read_at: Time.now) unless n.read_at
    return_success(n.as_pos)
  end

  def mark_all_read
    Notification.where(user_id: App.cu.id, read_at: nil).update(read_at: Time.now)
    return_success(unread: 0)
  end

  private

  def own(id)
    Notification[user_id: App.cu.id, id: id.to_i] || return_errors!('Notification not found', 404)
  end

  def unread_count
    Notification.where(user_id: App.cu.id, read_at: nil).count
  end
end
