require "test_helper"
require "yaml"

module ConcurrentPipeline
  class IntegrationTest < Test
    [:async, :sync].each do |sync|
      define_method("test_#{sync}__basic") do
        tmpdir = Dir.mktmpdir

        store = Store.define do
          storage(:yaml, dir: tmpdir)

          record(:main) do
            attribute(:started)
          end

          record(:record_1) do
            attribute(:processed)
          end
        end

        # Create an initial main record to kick off processing
        store.create(:main, started: false)

        pipeline = Pipeline.define do
          processor(sync)

          process(-> { store.all(:main).reject(&:started) }) do |record|
            5.times do |id|
              store.create(:record_1, id:, processed: false)
            end

            store.update(record, started: true)
          end

          process(-> { store.all(:record_1).reject(&:processed)}) do |record|
            store.update(record, processed: true)
          end
        end

        pipeline.process(store)

        assert_equal 5, store.all(:record_1).count
        assert store.all(:main).all?(&:started)
        assert store.all(:record_1).all?(&:processed)
      end

      define_method("test_#{sync}__error_handling") do
        tmpdir = Dir.mktmpdir

        store = Store.define do
          storage(:yaml, dir: tmpdir)

          record(:main) do
            attribute(:started)
          end

          record(:record_1) do
            attribute(:processed)
          end
        end

        # Create an initial main record to kick off processing
        store.create(:main, started: false)

        pipeline = Pipeline.define do
          processor(sync)

          process(-> { store.all(:main).reject(&:started) }) do |record|
            5.times do |id|
              store.create(:record_1, id:, processed: false)
            end

            store.update(record, started: true)
          end

          process(-> { store.all(:record_1).reject(&:processed)}) do |record|
            raise "nope"
            store.update(record, processed: true)
          end
        end

        refute pipeline.process(store)
        refute pipeline.errors.empty?
        assert pipeline.errors.all? { _1.is_a?(RuntimeError) }

        assert store.all(:main).all?(&:started)
        refute store.all(:record_1).any?(&:processed)  # None should be processed since all raise
      end

      define_method("test_#{sync}__filters") do
        tmpdir = Dir.mktmpdir

        store = Store.define do
          storage(:yaml, dir: tmpdir)

          record(:main) do
            attribute(:started)
          end

          record(:record_1) do
            attribute(:processed)
          end
        end

        # Create an initial main record to kick off processing
        store.create(:main, started: false)

        pipeline = Pipeline.define do
          processor(sync)

          # Using the new simpler interface with (record_name, **filters)
          process(:main, started: false) do |record|
            5.times do |id|
              store.create(:record_1, id:, processed: false)
            end

            store.update(record, started: true)
          end

          # Using the new simpler interface with (record_name, **filters)
          process(:record_1, processed: false) do |record|
            store.update(record, processed: true)
          end
        end

        pipeline.process(store)

        assert_equal 5, store.all(:record_1).count
        assert store.all(:main).all?(&:started)
        assert store.all(:record_1).all?(&:processed)
      end

      define_method("test_#{sync}__stops_on_error") do
        tmpdir = Dir.mktmpdir

        store = Store.define do
          storage(:yaml, dir: tmpdir)

          record(:record_1) do
            attribute(:processed)
            attribute(:id)
          end
        end

        # Create many records
        20.times do |id|
          store.create(:record_1, id:, processed: false)
        end

        processed_count = 0
        pipeline = Pipeline.define do
          if sync == :async
            processor(sync, concurrency: 1)
          else
            processor(sync)
          end

          process(:record_1, processed: false) do |record|
            processed_count += 1
            # Fail on the first record
            raise "Error on first record" if record.id == 0
            store.update(record, processed: true)
          end
        end

        refute pipeline.process(store)
        refute pipeline.errors.empty?

        # Only the first record should have been attempted
        # Enqueued tasks should have exited early without processing
        assert_equal 1, processed_count, "Only 1 record should have been processed before stopping"

        # No records should have been successfully processed
        refute store.all(:record_1).any?(&:processed)
      end
    end
  end
end
