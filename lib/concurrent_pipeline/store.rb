require "active_record"

module ConcurrentPipeline
  class Store
    def self.define(&block)
      schema = Stores::Schema.new
      schema.instance_exec(&block)

      klass = Class.new(Store) do
        define_method(:schema) { schema }
      end

      schema.records.each do |name, spec|
        define_method(name) { class_for(spec) }
      end

      klass.new(schema:, version: :root)
    end

    attr_reader :schema, :version
    def initialize(schema:, version:)
      @schema = schema
      @version = version
      @klasses = {}

      # eagerly construct classes
      schema.records.each_value { class_for(_1) }
    end

    def transaction(&)
      base_class.transaction(&)
    end

    def versions
      return [self] unless root?

      version_files = Dir.glob(File.join(schema.dir, "versions", "*.sqlite3")).sort
      version_files.map do |file|
        version_num = File.basename(file, ".sqlite3").to_i
        Store.new(schema: schema, version: version_num)
      end
    end

    def restore
      raise "Can only restore from a version snapshot, not from root" if root?

      # Copy the version database to the main database
      main_db = File.join(schema.dir, "db.sqlite3")
      FileUtils.cp(db_path, main_db)

      # Renumber versions: keep all versions up to and including this one,
      # then create a new version snapshot for the restore
      version_files = Dir.glob(File.join(schema.dir, "versions", "*.sqlite3")).sort
      version_files.each do |file|
        file_version = File.basename(file, ".sqlite3").to_i
        if file_version > version
          FileUtils.rm(file)
        end
      end

      # Create a new version snapshot of the restored state
      new_version_num = version + 1
      version_file = File.join(schema.dir, "versions", "#{new_version_num}.sqlite3")
      FileUtils.cp(main_db, version_file)

      # Return a new root store for the restored state
      Store.new(schema: schema, version: :root)
    end

    private

    def schema_root_mod_name
      @schema_root_mod_name ||+ "SchemaRoot_#{schema.object_id}_#{object_id}"
    end

    def schema_root_mod
      @schema_root_mod ||= (
        if Store.const_defined?(schema_root_mod_name)
          Store.const_get(schema_root_mod_name)
        else
          Module.new.tap { Store.const_set(schema_root_mod_name, _1) }
        end
      )
    end

    def base_class
      @base_class ||= (
        me = self
        klass = Class.new(ActiveRecord::Base) do
          define_singleton_method(:transaction_mutex) do
            @transaction_mutex ||= Mutex.new
          end

          define_singleton_method(:class_name) do |name|
            "#{me.send(:schema_root_mod)}::Record_#{name}"
          end

          define_singleton_method(:transaction) do |**options, &block|
            # If already in a transaction, just call super without creating a backup
            return super(**options, &block) if connection.transaction_open?

            transaction_mutex.synchronize do
              result = super(**options, &block)

              timestamp = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
              backup_path = File.join(me.schema.dir, "versions/#{timestamp}.sqlite3")
              FileUtils.mkdir_p(File.dirname(backup_path))
              FileUtils.cp(me.send(:db_path), backup_path)

              result
            end
          end
        end

        # ActiveRecord doesn't let this be anonymous?
        schema_root_mod.const_set(
          "Base",
          klass
        )

        klass.abstract_class = true
        klass.establish_connection(
          adapter: 'sqlite3',
          database: db_path
        )

        # Configure SQLite to use DELETE journal mode instead of WAL
        # This avoids creating -wal and -shm files
        klass.connection.execute("PRAGMA journal_mode=DELETE")
        klass.connection.execute("PRAGMA locking_mode=NORMAL")

        # Only run migrations for the root store, not for version snapshots
        if root? && schema.migrations.any?
          # Ensure schema_migrations table exists
          unless klass.connection.table_exists?(:schema_migrations)
            klass.connection.create_table(:schema_migrations, id: false) do |t|
              t.string :version, null: false
            end
            klass.connection.add_index(:schema_migrations, :version, unique: true)
          end

          # Run any migrations that haven't been run yet
          schema.migrations.each do |migration|
            version = migration.version.to_s

            # Check if migration has already been run using quote method for SQL safety
            existing = klass.connection.select_value(
              "SELECT 1 FROM schema_migrations WHERE version = #{klass.connection.quote(version)} LIMIT 1"
            )
            next if existing

            # Run the migration
            klass.connection.instance_exec(&migration.block)

            # Record that this migration has been run
            klass.connection.execute(
              "INSERT INTO schema_migrations (version) VALUES (#{klass.connection.quote(version)})"
            )
          end
        end

        klass
      )
    end

    def class_for(spec)
      @klasses[spec.name] ||= (
        store = self
        Class.new(base_class) do
          self.table_name = spec.table

          # Execute the block if present, but define a schema method to ignore schema calls
          if spec.block
            # Define a no-op schema method to prevent errors when the block tries to call it
            define_singleton_method(:schema) { |*args, &blk| }
            class_exec(&spec.block)
            # Remove the schema method after execution
            singleton_class.remove_method(:schema) rescue nil
          end

          # Make all records readonly if this is a version snapshot
          if not store.send(:root?)
            define_method(:readonly?) { true }
          end
        end
      ).tap {
        schema_root_mod.const_set("Record_#{spec.name}", _1)
      }
    end

    def db_path
      @db_path ||= (
        if root?
          File.join(schema.dir, "db.sqlite3")
        else
          File.join(schema.dir, "versions", "#{version}.sqlite3")
        end
      )
    end

    def root?
      version == :root
    end
  end
end
