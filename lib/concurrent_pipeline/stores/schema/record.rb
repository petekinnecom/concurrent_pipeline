module ConcurrentPipeline
  module Stores
    class Schema
      class Record
        class << self
          def attribute(name, **options)
            attributes << name
            attribute_defaults[name] = options[:default] if options.key?(:default)

            define_method(name) do
              attributes[name]
            end

            define_method("#{name}=") do |value|
              @attributes[name] = value
            end
          end

          def attributes
            @attributes ||= []
          end

          def attribute_defaults
            @attribute_defaults ||= {}
          end

          def inherited(mod)
            mod.attribute(:id)
          end
        end

        attr_reader :attributes
        def initialize(attributes = {})
          # Apply defaults for missing attributes
          defaults = self.class.attribute_defaults
          @attributes = self.class.attributes.each_with_object({}) do |attr_name, hash|
            if attributes.key?(attr_name)
              hash[attr_name] = attributes[attr_name]
            elsif defaults.key?(attr_name)
              hash[attr_name] = defaults[attr_name]
            end
          end
        end
      end
    end
  end
end
