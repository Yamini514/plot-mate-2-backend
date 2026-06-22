Sequel.migration do
  change do
    # Lifecycle status of the plot itself, distinct from its payment_status.
    # The interactive map colours each plot from a blend of the two (e.g. a
    # `sold` plot that is also overdue shows as overdue). available is the
    # natural default for a freshly created plot.
    alter_table(:plots) do
      add_column :status, String, default: 'available'  # available | booked | sold | blocked
    end

    # Upgrade the clickable regions from rectangles to arbitrary polygons, and
    # let a region instead be a non-clickable map *label* (road / park / open
    # space). Everything here is additive — the existing rectangle editor keeps
    # writing x/y/w/h and reading them back unchanged.
    alter_table(:plot_map_regions) do
      # JSON array of [x, y] vertex pairs, each a normalized percentage (0..100)
      # of the image box — same coordinate space as x/y/w/h, which stay as the
      # polygon's bounding box (used for fallback rendering + centroid/zoom).
      # Stored as text and (de)serialized in the model to avoid pg_json casting
      # quirks in multi_insert. Null ⇒ treat the region as a plain rectangle.
      add_column :points, String, text: true

      # 'plot'  → clickable, linked to a plot_id
      # 'label' → static text (road/park/open space), never clickable
      add_column :kind, String, default: 'plot'

      add_column :label, String         # e.g. "40 FT ROAD", "PARK AREA"
      add_column :label_type, String    # road | park | open_space | amenity

      # Label regions have no plot, so plot_id must be nullable now. The model
      # enforces presence only for kind = 'plot'.
      set_column_allow_null :plot_id
    end
  end
end
