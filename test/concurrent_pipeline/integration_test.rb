require "test_helper"

module ConcurrentPipeline
  class IntegrationTest < Test
    [:async, :sync].each do |sync|
      define_method("test_#{sync}__basic") do
        tmpdir = Dir.mktmpdir

        store = ConcurrentPipeline.store do |base|
          dir(tmpdir)

          migrate do
            create_table(:mains) do |t|
              t.boolean(:started, default: false)
            end

            create_table(:record_1s) do |t|
              t.integer(:record_id)
              t.boolean(:processed, default: false)
            end
          end

          record(:main, table: :mains)
          record(:record_1, table: :record_1s)
        end

        # Create an initial main record to kick off processing
        store.transaction do
          store.main.create!
        end

        pipeline = Pipeline.define do
          processor(sync)

          process(store.main.where(started: false)) do |record|
            5.times do |id|
              store.record_1.create!(record_id: id)
            end

            record.update!(started: true)
          end

          process(store.record_1.where(processed: false)) do |record|
            record.update!(processed: true)
          end
        end

        pipeline.process(store)

        assert_equal 5, store.record_1.count
        assert store.main.all.all?(&:started)
        assert store.record_1.all.all?(&:processed)
      end

      define_method("test_#{sync}__error_handling") do
        tmpdir = Dir.mktmpdir

        store = ConcurrentPipeline.store do |base|
          dir(tmpdir)

          migrate do
            create_table(:mains) do |t|
              t.boolean(:started, default: false)
            end

            create_table(:record_1s) do |t|
              t.integer(:record_id)
              t.boolean(:processed, default: false)
            end
          end

          record(:main, table: :mains)
          record(:record_1, table: :record_1s)
        end

        # Create an initial main record to kick off processing
        store.transaction do
          store.main.create!
        end

        pipeline = Pipeline.define do
          processor(sync)

          process(store.main.where(started: false)) do |record|
            5.times do |id|
              store.record_1.create!(record_id: id)
            end

            record.update!(started: true)
          end

          process(store.record_1.where(processed: false)) do |record|
            raise "nope"
            record.update!(processed: true)
          end
        end

        result = pipeline.process(store)
        refute result.success?
        refute result.errors.empty?
        assert result.errors.all? { _1.is_a?(RuntimeError) }

        assert store.main.all.all?(&:started)
        refute store.record_1.all.any?(&:processed)  # None should be processed since all raise
      end

      define_method("test_#{sync}__filters") do
        tmpdir = Dir.mktmpdir

        store = ConcurrentPipeline.store do |base|
          dir(tmpdir)

          migrate do
            create_table(:mains) do |t|
              t.boolean(:started, default: false)
            end

            create_table(:record_1s) do |t|
              t.integer(:record_id)
              t.boolean(:processed, default: false)
            end
          end

          record(:main, table: :mains)
          record(:record_1, table: :record_1s)
        end

        # Create an initial main record to kick off processing
        store.transaction do
          store.main.create!
        end

        pipeline = Pipeline.define do
          processor(sync)

          # Using ActiveRecord where clauses for filtering
          process(store.main.where(started: false)) do |record|
            5.times do |id|
              store.record_1.create!(record_id: id)
            end

            record.update!(started: true)
          end

          # Using ActiveRecord where clauses for filtering
          process(store.record_1.where(processed: false)) do |record|
            record.update!(processed: true)
          end
        end

        pipeline.process(store)

        assert_equal 5, store.record_1.count
        assert store.main.all.all?(&:started)
        assert store.record_1.all.all?(&:processed)
      end

      define_method("test_#{sync}__stops_on_error") do
        tmpdir = Dir.mktmpdir

        store = ConcurrentPipeline.store do |base|
          dir(tmpdir)

          migrate do
            create_table(:record_1s) do |t|
              t.integer(:record_id)
              t.boolean(:processed, default: false)
            end
          end

          record(:record_1, table: :record_1s)
        end

        # Create many records
        store.transaction do
          20.times do |id|
            store.record_1.create!(record_id: id)
          end
        end

        processed_count = 0
        pipeline = Pipeline.define do
          if sync == :async
            processor(sync, concurrency: 1)
          else
            processor(sync)
          end

          process(store.record_1.where(processed: false)) do |record|
            processed_count += 1
            # Fail on the first record
            raise "Error on first record" if record.record_id == 0
            record.update!(processed: true)
          end
        end

        result = pipeline.process(store)
        refute result.success?
        refute result.errors.empty?

        # Only the first record should have been attempted
        # Enqueued tasks should have exited early without processing
        assert_equal 1, processed_count, "Only 1 record should have been processed before stopping"

        # No records should have been successfully processed
        refute store.record_1.all.any?(&:processed)
      end
    end

    def test_versioning_and_validations
      tmpdir = Dir.mktmpdir

      store = ConcurrentPipeline.store do |base|
        dir(tmpdir)

        migrate do
          create_table(:mains) do |t|
            t.boolean(:todos_created, default: false)
          end

          create_table(:todos) do |t|
            t.string(:task, null: false)
            t.boolean(:completed, default: false, null: false)

            t.timestamps
          end
        end

        record(:main, table: :mains)

        record(:todo, table: :todos) do
          validates :task, presence: true
        end
      end

      store.transaction do
        store.main.create!
      end

      pipeline = Pipeline.define do
        processor(:sync)

        process(store.main.where(todos_created: false)) do |main|
          ["a", "b", "c"].each do |task|
            store.todo.create!(task:)
          end

          main.update!(todos_created: true)
        end

        process(store.todo.where(completed: false)) do |todo|
          todo.update!(completed: true)
        end
      end

      result = pipeline.process(store)
      assert result.success?
      assert_empty result.errors

      assert_equal 3, store.todo.count
      assert_equal(["a", "b", "c"], store.todo.pluck(:task))
      assert store.todo.all.all?(&:completed?)

      # Test versioning functionality
      assert_equal 5, store.versions.length
      refute store.versions[0].main.first.todos_created
      assert store.versions[1].main.first.todos_created
    end

    [:async, :sync].each do |sync|
      define_method("test_#{sync}__before_process_hook") do
        tmpdir = Dir.mktmpdir

        store = ConcurrentPipeline.store do |base|
          dir(tmpdir)

          migrate do
            create_table(:tasks) do |t|
              t.integer(:task_id)
              t.boolean(:processed, default: false)
            end
          end

          record(:task, table: :tasks)
        end

        # Create some records
        store.transaction do
          5.times do |id|
            store.task.create!(task_id: id)
          end
        end

        progress_events = []
        pipeline = Pipeline.define do
          if sync == :async
            processor(sync, concurrency: 1)
          else
            processor(sync)
          end

          before_process do |step|
            progress_events << {
              value: step.value,
            }
          end

          process(store.task.where(processed: false)) do |task|
            task.update!(processed: true)
          end
        end

        pipeline.process(store)

        # Verify all tasks were processed
        assert store.task.all.all?(&:processed)

        # Verify progress events were recorded
        assert_equal 5, progress_events.size

        # Verify each event has a value (the task record)
        progress_events.each do |event|
          assert_kind_of store.task, event[:value]
        end
      end

      define_method("test_#{sync}__before_process_with_labels") do
        tmpdir = Dir.mktmpdir

        store = ConcurrentPipeline.store do |base|
          dir(tmpdir)

          migrate do
            create_table(:tasks) do |t|
              t.integer(:task_id)
              t.boolean(:processed, default: false)
            end

            create_table(:subtasks) do |t|
              t.integer(:task_id)
              t.boolean(:completed, default: false)
            end
          end

          record(:task, table: :tasks)
          record(:subtask, table: :subtasks)
        end

        # Create some records
        store.transaction do
          3.times do |id|
            store.task.create!(task_id: id)
          end
        end

        progress_events = []
        pipeline = Pipeline.define do
          if sync == :async
            processor(sync, concurrency: 1)
          else
            processor(sync)
          end

          before_process do |step|
            progress_events << {
              value: step.value,
              label: step.label
            }
          end

          process(store.task.where(processed: false), label: "process_tasks") do |task|
            2.times do |i|
              store.subtask.create!(task_id: task.task_id)
            end
            task.update!(processed: true)
          end

          process(store.subtask.where(completed: false), label: "process_subtasks") do |subtask|
            subtask.update!(completed: true)
          end
        end

        pipeline.process(store)

        # Verify all records were processed
        assert store.task.all.all?(&:processed)
        assert store.subtask.all.all?(&:completed)

        # Verify progress events were recorded (3 tasks + 6 subtasks = 9)
        assert_equal 9, progress_events.size

        # Verify labels are present
        task_events = progress_events.select { |e| e[:label] == "process_tasks" }
        subtask_events = progress_events.select { |e| e[:label] == "process_subtasks" }

        assert_equal 3, task_events.size
        assert_equal 6, subtask_events.size

        # Verify task events have task records
        task_events.each do |event|
          assert_kind_of store.task, event[:value]
        end

        # Verify subtask events have subtask records
        subtask_events.each do |event|
          assert_kind_of store.subtask, event[:value]
        end
      end

      define_method("test_#{sync}__timer_hook") do
        tmpdir = Dir.mktmpdir

        store = ConcurrentPipeline.store do |base|
          dir(tmpdir)

          migrate do
            create_table(:tasks) do |t|
              t.integer(:task_id)
              t.boolean(:processed, default: false)
            end
          end

          record(:task, table: :tasks)
        end

        # Create some records
        store.transaction do
          10.times do |id|
            store.task.create!(task_id: id)
          end
        end

        timer_calls = []
        pipeline = Pipeline.define do
          if sync == :async
            processor(sync, concurrency: 1)
          else
            processor(sync)
          end

          timer(0.1) do
            timer_calls << Time.now
          end

          process(store.task.where(processed: false)) do |task|
            sleep(0.05)  # Make processing take some time
            task.update!(processed: true)
          end
        end

        pipeline.process(store)

        # Verify all tasks were processed
        assert store.task.all.all?(&:processed)

        # Verify timer was called multiple times
        assert timer_calls.size >= 2, "Timer should be called at least twice"

        # Verify timer was called approximately every 0.1 seconds
        if timer_calls.size >= 2
          intervals = timer_calls.each_cons(2).map { |t1, t2| t2 - t1 }
          avg_interval = intervals.sum / intervals.size
          # Allow some tolerance (between 0.08 and 0.15 seconds)
          assert avg_interval >= 0.08, "Average interval too short: #{avg_interval}"
          assert avg_interval <= 0.15, "Average interval too long: #{avg_interval}"
        end
      end

      define_method("test_#{sync}__timer_with_stats") do
        tmpdir = Dir.mktmpdir

        store = ConcurrentPipeline.store do |base|
          dir(tmpdir)

          migrate do
            create_table(:tasks) do |t|
              t.integer(:task_id)
              t.boolean(:processed, default: false)
            end
          end

          record(:task, table: :tasks)
        end

        # Create some records
        store.transaction do
          5.times do |id|
            store.task.create!(task_id: id)
          end
        end

        stats_snapshots = []
        pipeline = Pipeline.define do
          if sync == :async
            processor(sync, concurrency: 1)
          else
            processor(sync)
          end

          timer(0.1) do |stats|
            stats_snapshots << {
              queue_size: stats.queue_size,
              completed: stats.completed,
              time: stats.time
            }
          end

          process(store.task.where(processed: false)) do |task|
            sleep(0.05)  # Make processing take some time
            task.update!(processed: true)
          end
        end

        pipeline.process(store)

        # Verify all tasks were processed
        assert store.task.all.all?(&:processed)

        # Verify stats were captured
        assert stats_snapshots.size >= 2, "Should have multiple stat snapshots"

        # Verify stats structure
        stats_snapshots.each do |snapshot|
          assert_kind_of Integer, snapshot[:queue_size]
          assert_kind_of Integer, snapshot[:completed]
          assert_kind_of Float, snapshot[:time]
          assert snapshot[:queue_size] >= 0
          assert snapshot[:completed] >= 0
          assert snapshot[:time] >= 0
        end

        # Verify queue_size decreases over time
        first_queue = stats_snapshots.first[:queue_size]
        last_queue = stats_snapshots.last[:queue_size]
        assert first_queue >= last_queue, "Queue size should decrease"

        # Verify completed increases over time
        first_completed = stats_snapshots.first[:completed]
        last_completed = stats_snapshots.last[:completed]
        assert last_completed >= first_completed, "Completed count should increase"

        # Verify time increases
        first_time = stats_snapshots.first[:time]
        last_time = stats_snapshots.last[:time]
        assert last_time > first_time, "Time should increase"

        # Final stats should show progress toward completion
        # Note: Last snapshot may be before final completion due to timing
        assert stats_snapshots.last[:completed] >= 3, "Should have completed at least 3"
        assert stats_snapshots.last[:completed] <= 5, "Should not exceed 5"
      end

      define_method("test_#{sync}__multiple_before_process_hooks") do
        tmpdir = Dir.mktmpdir

        store = ConcurrentPipeline.store do |base|
          dir(tmpdir)

          migrate do
            create_table(:tasks) do |t|
              t.integer(:task_id)
              t.boolean(:processed, default: false)
            end
          end

          record(:task, table: :tasks)
        end

        # Create some records
        store.transaction do
          3.times do |id|
            store.task.create!(task_id: id)
          end
        end

        hook1_events = []
        hook2_events = []
        hook3_events = []

        pipeline = Pipeline.define do
          if sync == :async
            processor(sync, concurrency: 1)
          else
            processor(sync)
          end

          # Register multiple hooks
          before_process do |step|
            hook1_events << step.value.task_id
          end

          before_process do |step|
            hook2_events << "task_#{step.value.task_id}"
          end

          before_process do |step|
            hook3_events << step.label
          end

          process(store.task.where(processed: false), label: "process_task") do |task|
            task.update!(processed: true)
          end
        end

        pipeline.process(store)

        # Verify all tasks were processed
        assert store.task.all.all?(&:processed)

        # Verify all hooks were called for each task
        assert_equal 3, hook1_events.size
        assert_equal 3, hook2_events.size
        assert_equal 3, hook3_events.size

        # Verify hook1 recorded task IDs
        assert_equal [0, 1, 2].sort, hook1_events.sort

        # Verify hook2 recorded formatted strings
        assert_equal ["task_0", "task_1", "task_2"].sort, hook2_events.sort

        # Verify hook3 recorded labels
        assert_equal ["process_task", "process_task", "process_task"], hook3_events
      end

      define_method("test_#{sync}__assert_method_success") do
        tmpdir = Dir.mktmpdir

        store = ConcurrentPipeline.store do |base|
          dir(tmpdir)

          migrate do
            create_table(:records) do |t|
              t.string(:status, default: "ready")
              t.boolean(:processed, default: false)
            end
          end

          record(:record, table: :records)
        end

        # Create records
        store.transaction do
          3.times do
            store.record.create!(status: "ready")
          end
        end

        pipeline = Pipeline.define do
          processor(sync)

          process(store.record.where(processed: false)) do |record|
            # Simulate some processing that changes status
            record.update!(status: "completed")
            # Assert that status changed (this should pass)
            assert(record.status == "completed")
            record.update!(processed: true)
          end
        end

        result = pipeline.process(store)

        # Verify processing succeeded
        assert result.success?
        assert_empty result.errors
        assert store.record.all.all?(&:processed)
        assert store.record.all.all? { |r| r.status == "completed" }
      end

      define_method("test_#{sync}__assert_method_failure") do
        tmpdir = Dir.mktmpdir

        store = ConcurrentPipeline.store do |base|
          dir(tmpdir)

          migrate do
            create_table(:records) do |t|
              t.string(:status, default: "ready")
              t.boolean(:processed, default: false)
            end
          end

          record(:record, table: :records)
        end

        # Create records
        store.transaction do
          store.record.create!(status: "ready")
        end

        pipeline = Pipeline.define do
          processor(sync)

          process(store.record.where(processed: false)) do |record|
            # Simulate a scenario where status doesn't change as expected
            # (simulating an infinite loop protection scenario)
            record.update!(status: "ready")  # Status didn't change!

            # Assert that status changed - this should fail
            assert(record.status != "ready")

            record.update!(processed: true)
          end
        end

        result = pipeline.process(store)

        # Verify processing failed
        refute result.success?
        refute_empty result.errors
        assert_equal 1, result.errors.size
        assert_kind_of Errors::AssertionFailure, result.errors.first
        assert_equal "Post condition failed", result.errors.first.message

        # Verify record wasn't marked as processed
        refute store.record.first.processed
      end
    end
  end
end
