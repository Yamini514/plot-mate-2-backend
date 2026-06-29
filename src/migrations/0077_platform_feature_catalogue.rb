Sequel.migration do
  up do
    # Editable catalogue of platform features. Per-venture on/off still lives on
    # clients.settings['features']; this table defines WHAT features exist, their
    # default state, and which venture-admin nav hrefs each one gates. Seeded
    # from the original hardcoded list so behaviour is unchanged until edited.
    create_table(:platform_features) do
      primary_key :id
      String    :key, null: false, unique: true
      String    :label, null: false
      String    :description, text: true
      TrueClass :default_on, default: true
      column    :nav_hrefs, :jsonb, default: '[]'  # admin nav hrefs this feature controls
      TrueClass :active, default: true
      Integer   :sort, default: 0
      DateTime  :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime  :updated_at, default: Sequel::CURRENT_TIMESTAMP
    end

    seed = [
      ['maintenance',       'Maintenance Module',  'Preventive maintenance schedules & logs', true,  ['/admin/maintenance']],
      ['complaints',        'Complaints Module',   'Resident complaint tracking',             true,  ['/admin/complaints']],
      ['visitors',          'Visitor & Gate',      'Gate visitor & delivery management',      true,  ['/admin/security']],
      ['facility_booking',  'Facility Booking',    'Amenity reservations',                    true,  ['/admin/amenities']],
      ['marketplace',       'Marketplace',         'Community marketplace',                   false, []],
      ['vendor_management', 'Vendor Management',   'Vendor portal & work orders',             true,  []]
    ]
    require 'json'
    seed.each_with_index do |(key, label, desc, on, hrefs), i|
      from(:platform_features).insert(key: key, label: label, description: desc,
                                      default_on: on, nav_hrefs: hrefs.to_json,
                                      active: true, sort: i)
    end
  end

  down do
    drop_table(:platform_features)
  end
end
