Sequel.migration do
  change do
    # Delivery / package gate capture: a photo of the parcel/agent and the
    # sender's mobile, so the owner-notify carries proof + a contact.
    alter_table(:deliveries) do
      add_column :photo_url, String, text: true
      add_column :mobile, String
    end
  end
end
