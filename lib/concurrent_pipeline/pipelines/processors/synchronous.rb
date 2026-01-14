require "async"

module ConcurrentPipeline
  module Pipelines
    module Processors
      class Synchronous
        def self.call(...)
          new(...).call
        end

        attr_reader(
          :store,
          :producers,
          :locker,
          :errors,
          :before_process_hooks,
          :timers
        )
        def initialize(
          store:,
          producers:,
          before_process_hooks: [],
          timers: []
        )
          @store = store
          @producers = producers
          @locker = Locker.new
          @errors = []
          @before_process_hooks = before_process_hooks
          @timers = timers
          @completed = 0
          @start_time = nil
        end

        def call
          @start_time = Time.now
          Async { |task|
            # Start timer tasks
            timer_tasks = timers.map { |timer|
              task.async do
                loop do
                  sleep(timer.interval)
                  begin
                    stats = build_stats
                    timer.block.call(stats)
                  rescue => e
                    # Silently ignore timer errors to not break the pipeline
                  end
                end
              end
            }

            begin
              while(enqueue_all) do end
              Result.new(errors:)
            ensure
              timer_tasks.each(&:stop)
            end
          }.wait
        end

        def queue_size
          # Cannot use locker.locks because don't enqueue them all, just
          # process records one-by-one.
          producers.sum do |producer|
            producer.records(store).count do |record|
              !locker.locked?(producer:, record:)
            end
          end
        end

        private

        def build_stats
          Pipelines::Schema::Stats.new(
            queue_size: queue_size,
            completed: @completed,
            time: Time.now - @start_time
          )
        end

        def enqueue_all
          enqueued_any = false

          producers.each do |producer|
            records = producer.records(store)
            records.each_with_index do |record, index|
              next if locker.locked?(producer:, record:)

              enqueued_any = true
              locker.lock(producer:, record:)

              begin
                before_process_hooks.each do |hook|
                  Pipelines::Schema::Step.new(
                    value: record,
                    label: producer.label
                  ).then { hook.call(_1) }
                end

                store.transaction do
                  producer.call(record)
                end
                @completed += 1
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
