class App::Models::ProjectReaction < Sequel::Model
  KINDS = %w[like celebrate concerned].freeze

  def validate
    super
    validates_presence [:client_id, :project_id, :user_id]
  end
end
