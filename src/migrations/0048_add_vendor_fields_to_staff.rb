Sequel.migration do
  change do
    # Promote the staff/vendor row into a proper vendor profile: service
    # categories, compliance (license/insurance + expiry), SLA, pricing, and the
    # verified/preferred flags that gate eligibility for work-order assignment.
    alter_table(:staff) do
      add_column :email, String
      add_column :categories, :jsonb, default: '[]'   # ["plumbing","electrical"]
      add_column :license_no, String
      add_column :license_expiry, Date
      add_column :insurance_policy, String
      add_column :insurance_expiry, Date
      add_column :sla_response_hours, Integer
      add_column :rate_card, String, text: true       # free-form pricing / rate notes
      add_column :verified, TrueClass, default: false
      add_column :preferred, TrueClass, default: false
    end
  end
end
