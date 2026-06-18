require './src/app'
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