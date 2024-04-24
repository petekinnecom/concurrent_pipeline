require "async"
require "async/semaphore"

module ConcurrentPipeline
  module Pipelines
    module Processors
      class Asynchronous
        def self.call(...)
          new(...).call
        end

        attr_reader(:store, :producers, :locker, :concurrency, :enqueue_seconds, :errors)
        def initialize(store:, producers:, concurrency: 5, enqueue_seconds: 0.1)
          @store = store
          @producers = producers
          @concurrency = concurrency
          @enqueue_seconds = enqueue_seconds
          @locker = Locker.new
          @errors = []
        end

        def call
          Async { |task|
            semaphore = Async::Semaphore.new(concurrency)
            active_tasks = []
            result = true

            loop do
              # Set result to false if any task has failed
              if errors.any?
                result = false
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

            result  # Return false if there was a failure, true otherwise
          }.wait  # Wait for the async block to complete and return its value
        end

        def enqueue_all(semaphore, active_tasks, parent_task)
          enqueued_any = false

          producers.each do |producer|
            producer.records(store).each do |record|
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
                      store.transaction do
                        producer.call(record)
                      end
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
