require "async"
require "async/semaphore"

module ConcurrentPipeline
  module Pipelines
    module Processors
      class Asynchronous
        def self.call(...)
          new(...).call
        end

        attr_reader(
          :store,
          :producers,
          :locker,
          :concurrency,
          :enqueue_seconds,
          :errors,
          :before_process_hooks,
          :timers
        )
        def initialize(
          store:,
          producers:,
          concurrency: 5,
          enqueue_seconds: 0.1,
          before_process_hooks: [],
          timers: []
        )
          @store = store
          @producers = producers
          @concurrency = concurrency
          @enqueue_seconds = enqueue_seconds
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
            semaphore = Async::Semaphore.new(concurrency)
            active_tasks = []

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
              loop do
                if errors.any?
                  break
                end

                # Clean up finished tasks
                active_tasks.reject!(&:finished?)

                # Try to enqueue more work (only if no failure)
                enqueued_any = enqueue_all(semaphore, active_tasks, task)

                # Stop when nothing is being processed AND nothing new was enqueued
                break if active_tasks.empty? && !enqueued_any

                # Yield to allow other tasks to progress
                sleep(enqueue_seconds)
              end
            ensure
              # Stop all timer tasks
              timer_tasks.each(&:stop)
            end

            Result.new(errors:)
          }.wait  # Wait for the async block to complete and return its value
        end

        def queue_size
          locker.locks.size
        end

        private

        def build_stats
          Pipelines::Schema::Stats.new(
            queue_size: queue_size,
            completed: @completed,
            time: Time.now - @start_time
          )
        end

        def enqueue_all(semaphore, active_tasks, parent_task)
          enqueued_any = false

          producers.each do |producer|
            records = producer.records(store)
            records.each_with_index do |record, index|
              next if locker.locked?(producer:, record:)

              enqueued_any = true
              locker.lock(producer:, record:)


              # Spawn async task
              new_task = parent_task.async do
                begin
                  # Exit early if another task has already failed
                  next if errors.any?

                  semaphore.acquire do
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
                      # Append error to array to prevent async gem from logging it
                      errors << e
                    end
                  end
                ensure
                  locker.unlock(producer:, record:)
                end
              end

              active_tasks << new_task
            end
          end

          enqueued_any
        end
      end
    end
  end
end
