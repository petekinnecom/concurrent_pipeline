require "securerandom"
require "async"
require "async/semaphore"

module ConcurrentPipeline
  module Pipelines
    module Processors
      class Locker
        attr_reader(:locks)
        def initialize
          @locks = {}
        end

        def locked?(producer:, record:)
          locks.key?([producer, record.class.record_name, record.id])
        end

        def lock(producer:, record:)
          locks[[producer, record.class.record_name, record.id]] = true
        end

        def unlock(producer:, record:)
          locks.delete([producer, record.class.record_name, record.id])
        end
      end
    end
  end
end
