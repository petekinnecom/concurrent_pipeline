module ConcurrentPipeline
  module Pipelines
    module Processors
      class Synchronous
        def self.call(...)
          new(...).call
        end

        attr_reader(:store, :producers, :locker, :errors)
        def initialize(store:, producers:)
          @store = store
          @producers = producers
          @locker = Locker.new
          @errors = []
        end

        def call
          while(enqueue_all) do end
          errors.empty?
        end

        def enqueue_all
          enqueued_any = false

          producers.each do |producer|
            producer.records(store).each do |record|
              next if locker.locked?(producer:, record:)

              enqueued_any = true
              locker.lock(producer:, record:)

              begin
                store.transaction do
                  producer.call(record)
                end
              rescue => e
                errors << e
                return false
              ensure
                locker.unlock(producer:, record:)
              end
            end
          end

          enqueued_any
        end
      end
    end
  end
end
