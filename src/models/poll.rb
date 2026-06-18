class App::Models::Poll < Sequel::Model
  STATUSES = %w[active closed].freeze

  def validate
    super
    validates_presence [:client_id, :question]
  end

  # Cast a vote. Returns false if the user already voted or the poll is closed.
  def record_vote!(user_id, option_id)
    return false if status == 'closed'
    return false if App.db[:poll_votes].where(poll_id: id, user_id: user_id).count.positive?

    opts = (options || []).map { |o| o.transform_keys(&:to_s) }
    opt = opts.find { |o| o['id'] == option_id.to_s }
    return false unless opt

    App.db.transaction do
      App.db[:poll_votes].insert(client_id: client_id, poll_id: id, user_id: user_id, option_id: option_id.to_s)
      opt['votes'] = (opt['votes'] || 0) + 1
      self.options = opts
      self.total_voters = (total_voters || 0) + 1
      save_changes
    end
    true
  end

  def as_pos(user_id = nil)
    {
      id: id, code: code, question: question, description: description,
      options: options || [], status: status, closes_at: closes_at,
      total_voters: total_voters,
      voted: user_id ? App.db[:poll_votes].where(poll_id: id, user_id: user_id).count.positive? : nil
    }
  end
end
