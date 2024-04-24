module ConcurrentPipeline
  module Stores
    class Schema
      STORAGE = {
        yaml: Storage::Yaml
      }

      def build(name, attrs:)
        records.fetch(name).new(attrs)
      end

      def storage(type = nil, **attrs)
        @storage = STORAGE.fetch(type).new(**attrs) if type
        @storage
      end

      def record(name, &)
        records[name] = Class.new(Record) do
          define_singleton_method(:name) { "PipelineRecord.#{name}" }
          define_singleton_method(:record_name) { name }

          class_exec(&)

          define_method(:inspect) do
            "#<#{self.class.name} #{attributes.inspect[0..100]}>"
          end
        end
      end

      def records
        @records ||= {}
      end
    end
  end
end
