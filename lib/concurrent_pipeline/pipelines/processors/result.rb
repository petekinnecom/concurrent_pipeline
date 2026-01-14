module ConcurrentPipeline
  module Pipelines
    module Processors
      Result = Data.define(:errors) do
        def success?
          errors.empty?
        end
      end
    end
  end
end
