require "securerandom"

module ConcurrentPipeline
  class Store
    def self.define(&block)
      schema = Stores::Schema.new
      schema.instance_exec(&block)

      klass = Class.new(Store) do
        define_method(:schema) { schema }
      end


      klass.new(schema.storage)
    end

    attr_reader :storage
    def initialize(storage)
      @storage = storage
    end

    def transaction(&block)
      ensure_writable

      if storage.in_transaction?
        raise "Nested transactions are not supported"
      end

      storage.transaction(&block)

      nil
    end

    def create(record_name, **attrs)
      ensure_writable

      storage.create(
        name: record_name,
        attrs: { id: SecureRandom.uuid }.merge(attrs)
      )

      nil
    end

    def update(record, **attrs)
      ensure_writable

      # Create a temporary record to apply and validate setter methods
      temp_record = record.class.new(record.attributes)

      # Apply attributes using setter methods (will raise NoMethodError if attribute doesn't exist)
      attrs.each do |key, value|
        temp_record.public_send("#{key}=", value)
      end

      storage.update(
        name: record.class.record_name,
        id: record.id,
        attrs: temp_record.attributes
      )

      nil
    end

    def all(record_name)
      storage
        .all(name: record_name)
        .map { schema.build(record_name, attrs: _1) }
    end

    def where(record_name, **filters)
      records = all(record_name)

      return records if filters.empty?

      records.select do |record|
        filters.all? do |key, value|
          attr_value = record.public_send(key)
          if value.respond_to?(:call)
            value.call(attr_value)
          else
            attr_value == value
          end
        end
      end
    end

    def versions
      storage.versions.map { self.class.new(_1) }
    end

    def restore
      self.class.new(storage.restore)
    end

    def ensure_writable
      unless storage.writeable?
        raise "Unwritable storage: Must 'restore' it before you can write to it"
      end
    end
  end
end
