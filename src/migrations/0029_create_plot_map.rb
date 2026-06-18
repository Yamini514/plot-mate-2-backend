Sequel.migration do
  change do
    # The imported site plan. One active layout per association; the image is
    # stored inline as a data URL so the feature works without S3. When S3 is
    # configured later, write to `image_url` instead and leave `image_data` null.
    create_table(:plot_layouts) do
      primary_key :id
      Integer :client_id, null: false

      String  :name, default: 'Master plan'
      String  :image_data, text: true          # data URL (PNG/JPG) — current store
      String  :image_url                       # reserved for S3-hosted layouts

      TrueClass :active, default: true

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index [:client_id, :active]
    end

    # One clickable rectangle per plot, drawn over the layout in the admin editor.
    # Coordinates are normalized percentages (0..100) of the image box, so they
    # stay correct at any render size / zoom.
    create_table(:plot_map_regions) do
      primary_key :id
      Integer :client_id, null: false
      Integer :layout_id, null: false
      Integer :plot_id,   null: false

      Float :x, default: 0    # top-left x, % of image width
      Float :y, default: 0    # top-left y, % of image height
      Float :w, default: 0    # width,  % of image width
      Float :h, default: 0    # height, % of image height

      TrueClass :active, default: true

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index [:client_id, :layout_id]
      index [:layout_id, :plot_id]
    end
  end
end
