module ConcurrentPipeline
  module Stores
    class Schema
      Record = Data.define(:name, :table, :block)
      Migration = Data.define(:version, :block)

      class RecordContext
        attr_reader :schema_instance, :table_name

        def initialize(schema_instance)
          @schema_instance = schema_instance
          @table_name = nil
        end

        def schema(table_name, &block)
          # Store the table name for later use
          @table_name = table_name

          # Prepend schema migrations to front of the line
          # Wrap the block in a create_table call
          migration_block = Proc.new do
            create_table(table_name, &block)
          end

          schema_instance.prepend_migration(table_name, &migration_block)
        end

        def method_missing(...)
        end

        def respond_to_missing?(...)
          true
        end
      end

      attr_reader :migrations, :records
      def initialize
        @migrations = []
        @records = {}
        @migration_counter = 1
      end

      def dir(path = nil)
        @dir = path if path
        @dir
      end

      def migrate(version = @migration_counter += 1, &block)
        migrations << Migration.new(version: version, block: block)
      end

      def prepend_migration(version, &block)
        migrations.unshift(Migration.new(version: version, block: block))
      end

      def record(name, table: nil, &block)
        # If block is given, execute it in RecordContext to extract schema calls
        extracted_table = table
        if block
          context = RecordContext.new(self)
          context.instance_exec(&block)
          extracted_table ||= context.table_name
        end

        records[name] = Record.new(
          name: name,
          table: extracted_table,
          block: block
        )
      end
    end
  end
end
