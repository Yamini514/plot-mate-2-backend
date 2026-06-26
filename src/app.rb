module App
  class<<self
    attr_reader :db, :audit_db
    NUMBER_OF_CONNECTIONS = (ENV['POOL_SIZE'] || 5).to_i

    def development?
      env == 'development'
    end

    def logger
      @logger ||= Logger.new(STDOUT).tap { |l| l.level = Logger::INFO }
    end

    def env
      @env ||= ENV['RACK_ENV'] || 'development'
    end

    def root
      @root ||= File.expand_path(File.dirname(__FILE__) + '/../')
    end

    def require_blob(blb)
      Dir[File.join(root, 'src', blb)].each {|f| require f}
    end

    def db_url
      ENV['DB_URL'] || raise("DB_URL is not set — add it to Backend/.env or the environment")
    end

    # Loads KEY=value pairs from Backend/.env into ENV (without overriding
    # variables already present). Keeps secrets out of source and avoids
    # pulling in a dotenv dependency.
    def load_env!
      path = File.join(root, '.env')
      return unless File.exist?(path)

      File.foreach(path) do |line|
        line = line.strip
        next if line.empty? || line.start_with?('#')

        key, _, value = line.partition('=')
        key = key.strip
        next if key.empty?

        value = value.strip.gsub(/\A["']|["']\z/, '')
        ENV[key] ||= value
      end
    end

    def load!
      # Load environment before anything reads ENV (db_url, JWT secret, AWS)
      load_env!

      # First connect to the database
      connect_to_database
      
      # Load libraries before models
      require_blob('lib/**/*.rb')
      
      # Setup Sequel configuration
      setup_sequel!
      
      # Load helpers before models
      App.require_blob('helpers/*.rb')
      
      # Load models in the correct order
      require_blob('models/concerns/*.rb')
      require_blob('models/*.rb')
      require_blob('models/**/*.rb')
      
      # Load routes last
      require_relative 'routes'

      # Configure AWS with environment variables
      setup_aws_config
    end

    def connect_to_database
      @db = Sequel.connect(db_url, 
        max_connections: NUMBER_OF_CONNECTIONS, 
        logger: logger, 
        after_connect: Proc.new { logger.info("Database connection established") }
      )
      @db.extension(:connection_validator)
      # Log SQL only at DEBUG so the per-query dump doesn't flood STDOUT; the
      # logger stays at INFO (set below), so request lines and errors still show.
      @db.sql_log_level = :debug
      # Neon's pooler closes idle connections aggressively, so validate on every
      # checkout (a cheap SELECT 1). A long timeout lets stale connections through
      # and surfaces as "SSL connection has been closed unexpectedly".
      @db.pool.connection_validation_timeout = -1
    end
    
    def setup_aws_config
      # Use environment variables instead of hardcoded credentials
      aws_access_key = ENV['AWS_ACCESS_KEY_ID']
      aws_secret_key = ENV['AWS_SECRET_ACCESS_KEY']
      aws_region = ENV['AWS_REGION'] || 'us-east-1'
      
      Aws.config.update(
        region: aws_region,
        credentials: Aws::Credentials.new(aws_access_key, aws_secret_key),
      )
      
      logger.info("AWS configuration initialized for region: #{aws_region}")
    end

    def cu
      App::Helpers::CurrentUser
    end

    def generate_id
      Time.now.utc.strftime("%Y%m%d%k%M%S%L%N").to_i.to_s(36)
    end

    def setup_sequel!
      Sequel::Model.plugin :validation_helpers
      Sequel::Model.plugin :force_encoding, 'UTF-8'
      Sequel::Model.plugin(::SequelPlugin::SaveUserId)
      # Sequel::Model.plugin(::SequelPlugin::JsonValuesValidations)
      # Sequel::Model.plugin(::SequelPlugin::JsonValueTypecast)
      Sequel::Model.plugin(::SequelPlugin::DefaultJson)
      Sequel::Model.plugin :nested_attributes
      Sequel::Model.plugin :dirty
      Sequel::Model.plugin :json_serializer
      Sequel::Model.raise_on_save_failure = false
      Sequel.extension :core_extensions
      Sequel.extension :named_timezones
      Sequel.extension :pg_json_ops
      Sequel.extension :pg_array_ops
      db.extension :pg_json, :pg_array, :pg_enum
      db.wrap_json_primitives = true
      db.typecast_json_strings = true
    end
  end

  module Models
  end
  module Services
  end
  module Helpers; end
  module Router; end
end