class App::Models::PlatformSetting < Sequel::Model
  # Singleton store for platform-wide config. The defaults below are the shape
  # the super-admin Settings page edits — deep-merged over the stored row so a
  # newly added key is always present even on an old row. Nothing is hardcoded
  # in business logic; these are just the initial values.
  DEFAULTS = {
    'email'        => { 'smtp_host' => '', 'smtp_port' => 587, 'from_name' => 'PlotMate', 'from_email' => '' },
    'notifications'=> { 'approval_email' => true, 'rejection_email' => true, 'weekly_digest' => false },
    'onboarding'   => {
      'required_documents' => [
        { 'doc_type' => 'registration',    'label' => 'Venture Registration Certificate', 'required' => true },
        { 'doc_type' => 'layout_map',      'label' => 'Approved Layout / Site Map',        'required' => true },
        { 'doc_type' => 'ownership_proof', 'label' => 'Land Ownership Proof',              'required' => true },
        { 'doc_type' => 'tax',             'label' => 'Property Tax Receipt',              'required' => false }
      ],
      'auto_code_prefix' => 'REQ'
    },
    'defaults'  => { 'currency' => 'INR', 'timezone' => 'Asia/Kolkata', 'plot_status_palette' => 'default' },
    'platform'  => { 'support_email' => '', 'terms_url' => '', 'maintenance_mode' => false }
  }.freeze

  # Shallow-per-section deep merge: stored section values win, but missing
  # sections/keys fall back to DEFAULTS so the UI never sees an absent section.
  def effective
    stored = settings || {}
    DEFAULTS.each_with_object({}) do |(section, defs), h|
      h[section] = defs.is_a?(Hash) ? defs.merge(stored[section] || {}) : (stored[section] || defs)
    end
  end

  def as_pos = effective
end
