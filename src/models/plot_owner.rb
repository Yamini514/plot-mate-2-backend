class App::Models::PlotOwner < Sequel::Model
  # One owner of a plot. A plot may have several; exactly one is primary_owner
  # (kept in sync with plots.owner_name/phone/email by Plots#sync_primary!).
  def as_pos
    { id: id, plot_id: plot_id, user_id: user_id, name: name, phone: phone,
      email: email, share: share, primary_owner: primary_owner || false,
      created_at: created_at }
  end
end
