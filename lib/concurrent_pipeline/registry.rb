# frozen_string_literal: true

module ConcurrentPipeline
  class Registry
    def build(type, attributes)
      lookup.fetch(type).new(attributes)
    end

    def register(type, klass)
      if lookup.key?(type)
        raise <<~TXT
          Duplicate type: #{type} for class #{klass.name}. Use the `as:` \
          option to avoid this collision, eg `model(MyModel, as: :MyModel).
        TXT
      end

      lookup[type] = klass
    end

    def type_for(type)
      return type if lookup.key?(type)

      reverse_lookup = lookup.invert

      return reverse_lookup[type] if reverse_lookup.key?(type)

      raise ArgumentError, "Unknown type: #{type}"
    end

    private

    def lookup
      @lookup ||= {}
    end
  end
end
