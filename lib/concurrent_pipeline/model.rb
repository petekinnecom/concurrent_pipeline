# frozen_string_literal: true

module ConcurrentPipeline
  module Model
    module InstanceMethods
      attr_reader :attributes

      def initialize(attributes)
        @attributes = attributes
      end
    end

    def self.extended(base)
      base.include(InstanceMethods)
    end

    def inherited(base)
      base.instance_variable_set(:@attributes, attributes.dup)
    end

    def attributes
      @attributes ||= {}
    end

    def attribute(name, **opts)
      attributes[name] = opts

      define_method(name) { attributes[name] }
    end
  end
end
