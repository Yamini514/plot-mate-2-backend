Sequel.migration do
  up do
    # Multiple owners per plot (joint ownership). plots.owner_name/phone/email
    # stays as the denormalised PRIMARY owner for back-compat; this table is the
    # full roster.
    create_table(:plot_owners) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :plot_id, null: false
      Integer  :user_id                       # linked login, if any
      String   :name, null: false
      String   :phone
      String   :email
      String   :share                          # "50%" / "joint" — free-form
      TrueClass :primary_owner, default: false
      Integer  :created_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :plot_id]
    end

    # Structured owner contacts on the user profile.
    alter_table(:users) do
      add_column :family_members, :jsonb, default: '[]'      # [{name,relation,phone}]
      add_column :emergency_contacts, :jsonb, default: '[]'  # [{name,relation,phone}]
      add_column :nominees, :jsonb, default: '[]'            # [{name,relation,phone,share}]
    end

    # Backfill: every plot that already names an owner gets a primary plot_owner.
    from(:plots).exclude(owner_name: nil).each do |p|
      next if p[:owner_name].to_s.strip.empty?
      from(:plot_owners).insert(
        client_id: p[:client_id], plot_id: p[:id], name: p[:owner_name],
        phone: p[:phone], email: p[:email], primary_owner: true,
        created_at: Sequel::CURRENT_TIMESTAMP
      )
    end
  end

  down do
    drop_table(:plot_owners)
    alter_table(:users) do
      drop_column :family_members
      drop_column :emergency_contacts
      drop_column :nominees
    end
  end
end
