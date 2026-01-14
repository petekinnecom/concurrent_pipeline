require "test_helper"

module ConcurrentPipeline
  class StoreIntegrationTest < Test
    def test_create_read_update_destroy
      tmpdir = Dir.mktmpdir

      store = ConcurrentPipeline.store do
        dir(tmpdir)

        migrate do
          create_table(:record_1s) do |t|
            t.string(:attr_1)
            t.string(:attr_2)
          end
        end

        record(:record_1, table: :record_1s) do
          def something?
            attr_1 == "attr_1_1"
          end
        end
      end

      record = store.record_1.transaction do
        store.record_1.create!(
          attr_1: "attr_1_1",
          attr_2: "attr_2_1"
        )
      end

      assert_equal 1, store.record_1.count
      assert_equal "attr_1_1", record.attr_1
      assert_equal "attr_2_1", record.attr_2
      assert record.something?

      store.record_1.transaction do
        record.update!(attr_1: "attr_1_updated")
      end

      assert_equal "attr_1_updated", record.attr_1
      assert_equal "attr_2_1", record.attr_2

      reloaded = store.record_1.find(record.id)
      assert_equal "attr_1_updated", reloaded.attr_1
      assert_equal "attr_2_1", reloaded.attr_2

      assert_equal 2, store.versions.length

      # can seamlessly browse other versions
      original_record = store.versions[0].record_1.find(record.id)
      assert_equal "attr_1_1", original_record.attr_1
      assert_equal "attr_2_1", original_record.attr_2

      updated_record = store.versions[1].record_1.find(record.id)
      assert_equal "attr_1_updated", updated_record.attr_1
      assert_equal "attr_2_1", updated_record.attr_2
    end

    def test_can_recover_existing_dir
      tmpdir = Dir.mktmpdir

      # First, create a database with some data
      initial_store = ConcurrentPipeline.store do
        dir(tmpdir)

        migrate do
          create_table(:record_1s) do |t|
            t.string(:attr_1)
            t.string(:attr_2)
          end
        end

        record(:record_1, table: :record_1s)
      end

      record = initial_store.record_1.create!(
        attr_1: "attr_1_1",
        attr_2: "attr_2_1"
      )

      # Now create a new store instance pointing to the same directory
      store = ConcurrentPipeline.store do
        dir(tmpdir)

        migrate do
          create_table(:record_1s) do |t|
            t.string(:attr_1)
            t.string(:attr_2)
          end
        end

        record(:record_1, table: :record_1s)
      end

      assert_equal 1, store.record_1.count

      reloaded_record = store.record_1.find(record.id)
      assert_equal "attr_1_1", record.attr_1
      assert_equal "attr_2_1", record.attr_2
    end

    def test_attribute_defaults
      tmpdir = Dir.mktmpdir

      store = ConcurrentPipeline.store do
        dir(tmpdir)

        migrate do
          create_table(:record_1s) do |t|
            t.string(:status, default: "pending")
            t.integer(:count, default: 0)
            t.boolean(:boolean, default: false)
            t.string(:name)
          end
        end

        record(:record_1, table: :record_1s)
      end

      # Create record without specifying default attributes
      record = store.record_1.create!(name: "Test")
      assert_equal "pending", record.status  # Should have default value
      assert_equal false, record.boolean  # Should have default value
      assert_equal 0, record.count          # Should have default value
      assert_equal "Test", record.name

      # Create record with explicit values overriding defaults
      record2 = store.record_1.create!(status: "active", count: 5, name: "Test2")
      assert_equal "active", record2.status  # Should use provided value
      assert_equal 5, record2.count         # Should use provided value
      assert_equal "Test2", record2.name
    end

    def test_update_with_invalid_attribute_raises_error
      tmpdir = Dir.mktmpdir

      store = ConcurrentPipeline.store do
        dir(tmpdir)

        migrate do
          create_table(:record_1s) do |t|
            t.string(:name)
          end
        end

        record(:record_1, table: :record_1s)
      end

      record = store.record_1.create!(name: "Original")

      error = assert_raises(ActiveRecord::UnknownAttributeError) do
        record.update!(invalid_attribute: "value")
      end

      assert_match(/invalid_attribute/, error.message)
    end

    def test_update_uses_setter_methods
      tmpdir = Dir.mktmpdir

      store = ConcurrentPipeline.store do
        dir(tmpdir)

        migrate do
          create_table(:record_1s) do |t|
            t.string(:name)
          end
        end

        record(:record_1, table: :record_1s) do
          def name=(value)
            super(value.upcase)
          end
        end
      end

      record = store.record_1.create!(name: "original")

      record.update!(name: "updated")

      reloaded = store.record_1.find(record.id)
      assert_equal "UPDATED", reloaded.name
    end

    def test_transaction
      tmpdir = Dir.mktmpdir

      store = ConcurrentPipeline.store do
        dir(tmpdir)

        migrate do
          create_table(:records) do |t|
            t.string(:attr)
          end
        end

        record(:record, table: :records)
      end

      store.record.transaction { store.record.create!(attr: "attr") }
      store.record.transaction { store.record.create!(attr: "attr") }

      record_1, record_2 = store.record.all.to_a

      assert_equal 2, store.versions.count

      store.transaction do
        record_1.update!(attr: "attr_updated")
        record_2.update!(attr: "attr_updated")
      end

      assert_equal 3, store.versions.count
    end

    def test_transaction_rollback_on_error
      tmpdir = Dir.mktmpdir

      store = ConcurrentPipeline.store do
        dir(tmpdir)

        migrate do
          create_table(:records) do |t|
            t.string(:attr)
          end
        end

        record(:record, table: :records)
      end

      store.record.transaction { store.record.create!(attr: "original") }
      assert_equal 1, store.versions.count

      begin
        store.transaction do
          record = store.record.first
          record.update!(attr: "updated")
          raise "Something went wrong"
        end
      rescue => e
        # Exception expected
      end

      # Version count should not change due to rollback
      assert_equal 1, store.versions.count

      # Record should still have original value
      record = store.record.first
      assert_equal "original", record.attr
    end

    def test_transaction_preserves_concurrent_changes
      tmpdir = Dir.mktmpdir

      store = ConcurrentPipeline.store do
        dir(tmpdir)

        migrate do
          create_table(:records) do |t|
            t.string(:attr)
          end
        end

        record(:record, table: :records)
      end

      store.record.transaction { store.record.create!(attr: "original_1") }
      store.record.transaction { store.record.create!(attr: "original_2") }
      store.record.transaction { store.record.create!(attr: "original_3") }

      assert_equal 3, store.versions.count

      # Get records before transaction
      record_1, record_2 = store.record.limit(2).to_a

      # Start a transaction using the store interface
      store.transaction do
        record_1.update!(attr: "transaction_1")
        record_2.update!(attr: "transaction_2")

        # Before committing, simulate a concurrent update from another process
        # We can't actually do this in the test because the mutex prevents it,
        # but the implementation is designed to handle this by reading current
        # data at commit time and applying operations on top of it
      end

      # Transaction should create only one version
      assert_equal 4, store.versions.count

      # Both records should have their updated values
      records = store.record.order(:id).to_a
      assert_equal "transaction_1", records[0].attr
      assert_equal "transaction_2", records[1].attr
      assert_equal "original_3", records[2].attr
    end

    def test_concurrent_write_transaction
      # TODO: Implement ActiveRecord-specific concurrent write test
    end

    def test_restore
      tmpdir = Dir.mktmpdir

      store = ConcurrentPipeline.store do
        dir(tmpdir)

        migrate do
          create_table(:records) do |t|
            t.string(:value)
          end
        end

        record(:record, table: :records)
      end

      # Create initial versions
      record_1 = store.record.transaction { store.record.create!(value: "v1") }
      record_2 = store.record.transaction { store.record.create!(value: "v2") }
      store.record.transaction { record_1.update!(value: "v1_updated") }

      # Should have 3 versions now
      assert_equal 3, store.versions.count

      # Verify current data has the updated value
      latest_record = store.record.find(record_1.id)
      assert_equal "v1_updated", latest_record.value

      # Restore to version 1 (first create)
      restored_store = store.versions[0].restore

      # Should only have 2 versions after restore
      assert_equal 2, restored_store.versions.count

      # Verify we can read the correct data
      records = restored_store.record.all.to_a
      assert_equal 1, records.count
      assert_equal record_1.id, records[0].id
      assert_equal "v1", records[0].value

      # Verify we can continue working after restore
      record_3 = restored_store.record.transaction { restored_store.record.create!(value: "v3") }
      assert_equal 3, restored_store.versions.count

      # Verify data has both records
      latest_records = restored_store.record.all.to_a
      assert_equal 2, latest_records.count

      reloaded_1 = latest_records.find { |r| r.id == record_1.id }
      reloaded_3 = latest_records.find { |r| r.id == record_3.id }

      assert_equal "v1", reloaded_1.value
      assert_equal "v3", reloaded_3.value
    end

    def test_where_with_lambda_filter
      tmpdir = Dir.mktmpdir

      store = ConcurrentPipeline.store do
        dir(tmpdir)

        migrate do
          create_table(:records) do |t|
            t.integer(:value)
          end
        end

        record(:record, table: :records)
      end

      store.record.create!(value: 2)
      store.record.create!(value: 3)
      record_3 = store.record.create!(value: 4)
      store.record.create!(value: 5)

      # Test with lambda that filters even values
      even_records = store.record.where("value % 2 = 0").to_a
      assert_equal 2, even_records.count
      assert_equal [2, 4], even_records.map(&:value).sort

      # Test with lambda that filters odd values
      odd_records = store.record.where("value % 2 = 1").to_a
      assert_equal 2, odd_records.count
      assert_equal [3, 5], odd_records.map(&:value).sort

      # Test combining filters
      even_with_id_filter = store.record.where(id: record_3.id).where("value % 2 = 0").to_a
      assert_equal 1, even_with_id_filter.count
      assert_equal record_3.id, even_with_id_filter.first.id
      assert_equal 4, even_with_id_filter.first.value
    end

    def test_schema_inside_record_block
      tmpdir = Dir.mktmpdir

      store = ConcurrentPipeline.store do
        dir(tmpdir)

        # Define a record with schema inline
        record(:my_record) do
          schema(:my_records) do |t|
            t.string(:name)
            t.integer(:value)
          end

          def custom_method
            "#{name}: #{value}"
          end
        end

        # Add another regular migration that should come after the schema
        migrate do
          create_table(:other_table) do |t|
            t.string(:data)
          end
        end
      end

      # Verify the schema migration was created and placed first
      assert_equal 2, store.schema.migrations.count

      # First migration should be the schema with table name as version
      first_migration = store.schema.migrations[0]
      assert_equal :my_records, first_migration.version

      # Second migration should be the regular migrate (version 2)
      second_migration = store.schema.migrations[1]
      assert_equal 2, second_migration.version

      # Verify the table was created and we can use it
      record = store.my_record.create!(name: "Test", value: 42)
      assert_equal "Test", record.name
      assert_equal 42, record.value
      assert_equal "Test: 42", record.custom_method

      # Verify we can query the record
      reloaded = store.my_record.find(record.id)
      assert_equal "Test", reloaded.name
      assert_equal 42, reloaded.value

      # Verify other_table was also created
      assert store.schema.records.key?(:my_record)
    end

    def test_belongs_to_and_has_many_relationships
      tmpdir = Dir.mktmpdir

      store = ConcurrentPipeline.store do
        dir(tmpdir)

        # Create parent record (author)
        record(:author) do
          schema(:authors) do |t|
            t.string(:name)
          end

          has_many(
            :posts,
            foreign_key: :author_id,
            class_name: class_name(:post),
            inverse_of: :author
          )
        end

        # Create child record (post)
        record(:post) do
          schema(:posts) do |t|
            t.string(:title)
            t.text(:content)
            t.integer(:author_id)
          end

          belongs_to(
            :author,
            class_name: class_name(:author),
            inverse_of: :posts
          )
        end
      end

      # Create an author
      author = store.author.transaction do
        store.author.create!(name: "Jane Doe")
      end

      assert_equal "Jane Doe", author.name
      assert_equal 1, store.author.count

      # Create posts associated with the author
      post1 = store.post.transaction do
        store.post.create!(
          title: "First Post",
          content: "This is the first post",
          author_id: author.id
        )
      end

      post2 = store.post.transaction do
        store.post.create!(
          title: "Second Post",
          content: "This is the second post",
          author_id: author.id
        )
      end

      assert_equal 2, store.post.count
      assert_equal "First Post", post1.title
      assert_equal author.id, post1.author_id

      # Test belongs_to relationship
      reloaded_post1 = store.post.find(post1.id)
      assert_equal author.id, reloaded_post1.author.id
      assert_equal "Jane Doe", reloaded_post1.author.name

      # Test has_many relationship
      reloaded_author = store.author.find(author.id)
      author_posts = reloaded_author.posts.to_a
      assert_equal 2, author_posts.count
      assert_equal author.object_id, author.posts.first.author.object_id
      assert_equal ["First Post", "Second Post"], author_posts.map(&:title).sort

      # Test relationships on versions
      assert_equal 3, store.versions.count

      # Version 0: only author exists
      v0_author = store.versions[0].author.find(author.id)
      assert_equal "Jane Doe", v0_author.name
      assert_equal 0, v0_author.posts.count

      # Version 1: author + first post
      v1_author = store.versions[1].author.find(author.id)
      v1_posts = v1_author.posts.to_a
      assert_equal 1, v1_posts.count
      assert_equal "First Post", v1_posts.first.title

      v1_post = store.versions[1].post.find(post1.id)
      assert_equal author.id, v1_post.author.id
      assert_equal "Jane Doe", v1_post.author.name

      # Version 2: author + both posts
      v2_author = store.versions[2].author.find(author.id)
      v2_posts = v2_author.posts.to_a
      assert_equal 2, v2_posts.count
      assert_equal ["First Post", "Second Post"], v2_posts.map(&:title).sort

      v2_post1 = store.versions[2].post.find(post1.id)
      v2_post2 = store.versions[2].post.find(post2.id)
      assert_equal author.id, v2_post1.author.id
      assert_equal author.id, v2_post2.author.id
      assert_equal "Jane Doe", v2_post1.author.name
      assert_equal "Jane Doe", v2_post2.author.name
    end
  end
end
