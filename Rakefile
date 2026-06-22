require './src/app'

# Maps the bundled sample site plan (Backend/assets/sample-layout.jpg, a real
# 1290x1405 layout) into clickable plot polygons + road/park/open-space labels.
# The block rectangles below were traced over that image (pixel space) and are
# converted to the 0..100 percentages the map uses. The plan is a scanned CAD
# drawing and is slightly rotated, so the grids are a close-but-approximate
# overlay (fine for a demo, and every region is draggable in the map editor).
# Used by the `db:seed_plot_map` task below.
module SampleMap
  IMG_W = 1290
  IMG_H = 1405
  GX = 4
  GY = 4

  # Plot grids: {x, y, w, h, cols, rows} traced over the sample plan (pixels).
  BLOCKS = [
    { x: 52,  y: 72,  w: 168, h: 256, cols: 3, rows: 10 }, # top-left block
    { x: 24,  y: 350, w: 206, h: 412, cols: 4, rows: 14 }, # big left grid
    { x: 245, y: 638, w: 335, h: 112, cols: 9, rows: 3 },  # centre, above 40ft road
    { x: 245, y: 786, w: 335, h: 90,  cols: 9, rows: 2 },  # centre, below 40ft road
    { x: 24,  y: 792, w: 280, h: 86,  cols: 6, rows: 2 },  # bottom-left strip
  ].freeze

  # Non-clickable map labels, placed at their pixel centres on the plan.
  LABELS = [
    { x: 90,  y: 122, label: 'SOCIAL INFRA', type: 'open_space' },
    { x: 285, y: 150, label: 'PARK AREA',    type: 'park' },
    { x: 268, y: 285, label: 'UTILITY',      type: 'amenity' },
    { x: 360, y: 768, label: '40 FT ROAD',   type: 'road' },
    { x: 175, y: 215, label: '30 FT ROAD',   type: 'road' },
    { x: 600, y: 715, label: 'PARK',         type: 'park' },
    { x: 415, y: 612, label: 'OPEN LAND',    type: 'open_space' },
    { x: 205, y: 928, label: 'OPEN LAND',    type: 'open_space' },
  ].freeze

  module_function

  def cells
    BLOCKS.flat_map do |b|
      cw = (b[:w] - GX * (b[:cols] - 1)).to_f / b[:cols]
      ch = (b[:h] - GY * (b[:rows] - 1)).to_f / b[:rows]
      (0...b[:cols]).flat_map do |c|
        (0...b[:rows]).map { |r| { x: b[:x] + c * (cw + GX), y: b[:y] + r * (ch + GY), w: cw, h: ch } }
      end
    end
  end

  def cell_count = cells.size

  def image_data_url
    path = File.join(App.root, 'assets', 'sample-layout.jpg')
    abort "Sample image missing at #{path}" unless File.exist?(path)
    "data:image/jpeg;base64,#{Base64.strict_encode64(File.binread(path))}"
  end

  def generate(plots)
    cs = cells
    mapped = plots.first([plots.size, cs.size].min)
    regions = mapped.each_with_index.map { |p, i| region_for(cs[i], kind: 'plot', plot_id: p.id) }
    LABELS.each do |l|
      box = { x: l[:x] - 45, y: l[:y] - 13, w: 90, h: 26 }
      regions << region_for(box, kind: 'label', label: l[:label], label_type: l[:type])
    end
    { image: image_data_url, regions: regions, mapped: mapped }
  end

  def region_for(b, kind:, plot_id: nil, label: nil, label_type: nil)
    pts = [[b[:x], b[:y]], [b[:x] + b[:w], b[:y]], [b[:x] + b[:w], b[:y] + b[:h]], [b[:x], b[:y] + b[:h]]]
          .map { |x, y| [pct(x, IMG_W), pct(y, IMG_H)] }
    { kind: kind, plot_id: plot_id, label: label, label_type: label_type,
      x: pct(b[:x], IMG_W), y: pct(b[:y], IMG_H), w: pct(b[:w], IMG_W), h: pct(b[:h], IMG_H), points: pts }
  end

  def pct(v, dim) = (v.to_f / dim * 100).round(3)
end

namespace :db do
  desc "Run migrations"
  task :migrate, [:version] do |t, args|
    App.load_env!   # load DB_URL from Backend/.env, like the server boot path
    puts args, App.db_url
    require "sequel/core"
    Sequel.extension :migration
    version = args[:version].to_i if args[:version]
    puts version
    Sequel.connect(App.db_url) do |db|
      db.extension :pg_enum
      Sequel::Migrator.run(db, "src/migrations", target: version)
    end
  end

  # Seed the three demo logins advertised on the sign-in screen so the
  # "click to autofill" buttons (admin / member / guard) actually work.
  # Idempotent: re-running only fills gaps. The accounts are attached to the
  # first existing client, so they see the same data the admin already manages.
  desc "Seed demo accounts (admin / member / guard)"
  task :seed do
    require 'bundler'
    Bundler.require(:default, App.env)
    App.load!

    client = App::Models::Client.where(active: true).order(:id).first
    client ||= App::Models::Client.create(name: 'Green Aero View', email: 'office@greenaeroview.in', active: true)
    puts "Using client ##{client.id} — #{client.name}"

    demo = [
      { email: 'admin@greenaeroview.in',  password: 'admin123',  role: 2,
        full_name: 'Suresh Kumar',  extras: { 'title' => 'Honorary Secretary' } },
      { email: 'member@greenaeroview.in', password: 'member123', role: 0,
        full_name: 'Naveen Varma',  extras: { 'title' => 'Plot Owner', 'plot_no' => 'P-047' } },
      { email: 'guard@greenaeroview.in',  password: 'guard123',  role: 1,
        full_name: 'Rajappa Gowda', extras: { 'title' => 'Security Guard · Main Gate', 'guard_id' => 'GRD-04' } },
    ]

    demo.each do |d|
      existing = App::Models::User.first(email: d[:email])
      # Never disturb an admin you already rely on — only create it if missing.
      if existing && d[:role] == 2
        puts "skip   #{d[:email]} (admin already exists — password left unchanged)"
        next
      end

      user = existing || App::Models::User.new(email: d[:email])
      user.client_id   = client.id
      user.full_name   = d[:full_name]
      user.role        = d[:role]
      user.active      = true
      user.extras      = d[:extras]
      user.password    = d[:password]  # model setter BCrypt-hashes it

      if user.save
        puts "#{existing ? 'update' : 'create'} #{d[:email]}  /  #{d[:password]}  (#{user.role_name})"
      else
        puts "FAILED #{d[:email]} — #{user.errors.full_messages.join(', ')}"
      end
    end

    puts "Done. Use the demo buttons on the login screen to sign in."
  end

  # Seed sample SMTP config onto the first active client (Settings → Email).
  # Values come from Backend/.env (EMAIL_* vars) so the password is never
  # hardcoded and stays in sync with the ENV fallback. Re-running overwrites
  # the stored config — handy for clearing a stale/wrong saved password.
  desc "Seed sample SMTP config on the first client (from .env)"
  task :seed_smtp do
    require 'bundler'
    Bundler.require(:default, App.env)
    App.load!

    client = App::Models::Client.where(active: true).order(:id).first
    abort 'No active client to attach SMTP config to — run `rake db:seed` first.' unless client

    user = ENV['EMAIL_USER'].to_s
    smtp = {
      'enabled'    => true,
      'host'       => ENV['EMAIL_SMTP_SERVER'].to_s.empty? ? 'smtp.gmail.com' : ENV['EMAIL_SMTP_SERVER'],
      'port'       => (ENV['EMAIL_PORT'] || 587).to_i,
      'username'   => user,
      'password'   => ENV['EMAIL_PASSWORD'].to_s,
      'security'   => 'starttls',
      'from_email' => user,                 # Gmail requires the from-address to be the authenticated account
      'from_name'  => client.name || 'PlotMate',
      'domain'     => ENV['EMAIL_DOMAIN'].to_s.empty? ? 'gmail.com' : ENV['EMAIL_DOMAIN']
    }

    client.settings = (client.settings || {}).merge('smtp' => smtp)
    client.save_changes

    puts "Seeded SMTP on client ##{client.id} — #{client.name}"
    puts "  host=#{smtp['host']} port=#{smtp['port']} user=#{smtp['username']} " \
         "security=#{smtp['security']} pw_len=#{smtp['password'].length}"
    puts '  WARNING: EMAIL_PASSWORD is empty in .env — set it before sending.' if smtp['password'].empty?
  end

  # Seed a ready-to-demo interactive plot map: the bundled sample site plan, a
  # clickable polygon per plot, and road/park/open-space labels — so /admin/plot-map
  # and /admin/plots both open fully populated. Idempotent: re-running replaces
  # the active layout and its regions. Requires migration 0033 to be applied.
  desc "Seed a sample plot map (real layout image + polygons + labels)"
  task :seed_plot_map do
    require 'bundler'
    require 'json'
    require 'base64'
    Bundler.require(:default, App.env)
    App.load!

    client = App::Models::Client.where(active: true).order(:id).first
    abort 'No active client — run `rake db:seed` first.' unless client
    cid = client.id

    # Make sure there are enough plots to fill the plan; top up a varied sample
    # set only when the client looks empty/demo (real data is left alone).
    target = SampleMap.cell_count
    if App::Models::Plot.where(client_id: cid, active: true).count < 20
      names  = ['Naveen Varma', 'Suresh Kumar', 'Anita Rao', 'Imran Khan', 'Priya Nair',
                'Rahul Mehta', 'Deepa Iyer', 'Vikram Shetty', 'Sana Patel', 'Arjun Das']
      phases = ['Phase 1', 'Phase 2', 'Phase 3', 'Phase 4']
      pays   = %w[paid pending unknown]
      (0...target).each do |i|
        no = format('P-%03d', i + 1)
        next if App::Models::Plot.where(client_id: cid, plot_no: no).first
        pay = pays[i % 3]
        App::Models::Plot.create(
          client_id: cid, plot_no: no, owner_name: names[i % names.size],
          phone: format('98%08d', 10_000_000 + i), email: "owner#{i + 1}@example.com",
          size_sqyd: [120, 150, 200, 240, 300][i % 5], phase: phases[[i / 36, 3].min],
          membership: i.even? ? 'verified' : 'unverified', payment_status: pay,
          amount_due_paise: pay == 'pending' ? 150_000 : 0,
          days_overdue: (i % 7 == 4 && pay == 'pending') ? 18 : 0,
          status: 'available', active: true,
        )
      end
      puts "Created sample plots (now #{App::Models::Plot.where(client_id: cid, active: true).count})."
    end

    plots = App::Models::Plot.where(client_id: cid, active: true).order(Sequel.asc(:plot_no)).all
    data  = SampleMap.generate(plots)

    # Spread the lifecycle statuses so all six map colours are visible. Only the
    # (new, additive) status field is touched — payment data is left untouched.
    cycle = %w[available booked sold blocked available sold booked]
    data[:mapped].each_with_index { |p, i| p.update(status: cycle[i % cycle.size]) }

    App.db.transaction do
      App::Models::PlotLayout.where(client_id: cid, active: true).update(active: false)
      layout = App::Models::PlotLayout.create(client_id: cid, name: 'Sample master plan',
                                              image_data: data[:image], active: true)
      App.db[:plot_map_regions].where(client_id: cid, layout_id: layout.id).delete
      rows = data[:regions].map do |r|
        {
          client_id: cid, layout_id: layout.id, kind: r[:kind], plot_id: r[:plot_id],
          label: r[:label], label_type: r[:label_type],
          x: r[:x], y: r[:y], w: r[:w], h: r[:h], points: r[:points].to_json,
          active: true, created_at: Time.now, updated_at: Time.now,
        }
      end
      App.db[:plot_map_regions].multi_insert(rows)
      labels = data[:regions].count { |r| r[:kind] == 'label' }
      puts "Seeded layout ##{layout.id}: #{data[:mapped].size} plot polygons + #{labels} labels."
    end

    puts 'Done. Open /admin/plot-map (and /admin/plots) to see the sample map.'
  end
end


require 'optparse'


namespace :create do
  desc "Creates Model"
  task :models do #|t, args|
    models = []
    OptionParser.new do |opts|
      puts opts
      opts.banner = "Usage: rake create:models [options]"
      opts.on("-n", "--names ARG", String) { |str| models += str.split(',') }

    end.parse!
    puts models
    exit
  end
end


# DATABASE_URL="postgres://doqhgpwk:faHZB60XTVMZTczxkznkvXC0rcHxyap6@rogue.db.elephantsql.com:5432/doqhgpwk" rake db:migrate\[0\]


# DATABASE_URL="postgres://exbkkjhk:teWF4qtJwyLZMXLm0CDM1eiYfNC-xr_T@satao.db.elephantsql.com:5432/exbkkjhk" rake db:migrate\[7\]
# DATABASE_URL="postgres://lnhtywgf:qfdIK2eJVhJlES3jAsyU4wZAxx1ESzfi@balarama.db.elephantsql.com:5432/lnhtywgf" rake db:migrate