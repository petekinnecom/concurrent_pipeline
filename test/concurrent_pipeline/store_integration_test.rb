require "test_helper"
require "yaml"

module ConcurrentPipeline
  class StoreIntegrationTest < Test
    def test_create_read_update_destroy
      tmpdir = Dir.mktmpdir

      store = Store.define do
        storage(:yaml, dir: tmpdir)

        record(:record_1) do
          attribute(:id)
          attribute(:attr_1)
          attribute(:attr_2)

          def something?
            attr_1 == "attr_1_1"
          end
        end
      end

      store.create(
        :record_1,
        id: "id_1",
        attr_1: "attr_1_1",
        attr_2: "attr_2_1"
      )

      assert_equal 1, store.all(:record_1).count

      record = store.all(:record_1).find { _1.id == "id_1" }
      assert_equal "attr_1_1", record.attr_1
      assert_equal "attr_2_1", record.attr_2
      assert record.something?

      store.update(record, attr_1: "attr_1_updated")
      assert_equal "attr_1_1", record.attr_1
      assert_equal "attr_2_1", record.attr_2

      reloaded = store.all(:record_1).find { _1.id == "id_1" }
      assert_equal "attr_1_updated", reloaded.attr_1
      assert_equal "attr_2_1", reloaded.attr_2

      assert_equal 2, store.versions.length

      # can seamlessly browse other versions
      original_record = store.versions[0].all(:record_1).find { _1.id == "id_1" }
      assert_equal "attr_1_1", original_record.attr_1
      assert_equal "attr_2_1", original_record.attr_2

      updated_record = store.versions[1].all(:record_1).find { _1.id == "id_1" }
      assert_equal "attr_1_updated", updated_record.attr_1
      assert_equal "attr_2_1", updated_record.attr_2
    end

    def test_can_recover_existing_dir
      tmpdir = Dir.mktmpdir

      File.write(
        File.join(tmpdir, "data.yml"),
        {
          record_1: {
            id_1: {
              id: "id_1",
              attr_1: "attr_1_1",
              attr_2: "attr_2_1"
            }
          }
        }.to_yaml
      )

      store = Store.define do
        storage(:yaml, dir: tmpdir)

        record(:record_1) do
          attribute(:id)
          attribute(:attr_1)
          attribute(:attr_2)
        end
      end

      assert_equal 1, store.all(:record_1).count

      record = store.all(:record_1).find { _1.id == "id_1" }
      assert_equal "attr_1_1", record.attr_1
      assert_equal "attr_2_1", record.attr_2
    end

    def test_attribute_defaults
      tmpdir = Dir.mktmpdir

      store = Store.define do
        storage(:yaml, dir: tmpdir)

        record(:record_1) do
          attribute(:id)
          attribute(:status, default: "pending")
          attribute(:count, default: 0)
          attribute(:boolean, default: false)
          attribute(:name)
        end
      end

      # Create record without specifying default attributes
      store.create(:record_1, id: "id_1", name: "Test")

      record = store.all(:record_1).find { _1.id == "id_1" }
      assert_equal "pending", record.status  # Should have default value
      assert_equal false, record.boolean  # Should have default value
      assert_equal 0, record.count          # Should have default value
      assert_equal "Test", record.name

      # Create record with explicit values overriding defaults
      store.create(:record_1, id: "id_2", status: "active", count: 5, name: "Test2")

      record2 = store.all(:record_1).find { _1.id == "id_2" }
      assert_equal "active", record2.status  # Should use provided value
      assert_equal 5, record2.count         # Should use provided value
      assert_equal "Test2", record2.name
    end

    def test_update_with_invalid_attribute_raises_error
      tmpdir = Dir.mktmpdir

      store = Store.define do
        storage(:yaml, dir: tmpdir)

        record(:record_1) do
          attribute(:id)
          attribute(:name)
        end
      end

      store.create(:record_1, id: "id_1", name: "Original")
      record = store.all(:record_1).find { _1.id == "id_1" }

      error = assert_raises(NoMethodError) do
        store.update(record, invalid_attribute: "value")
      end

      assert_match(/invalid_attribute=/, error.message)
    end

    def test_update_uses_setter_methods
      tmpdir = Dir.mktmpdir

      store = Store.define do
        storage(:yaml, dir: tmpdir)

        record(:record_1) do
          attribute(:id)
          attribute(:name)

          def name=(value)
            @attributes[:name] = value.upcase
          end
        end
      end

      store.create(:record_1, id: "id_1", name: "original")
      record = store.all(:record_1).find { _1.id == "id_1" }

      store.update(record, name: "updated")

      reloaded = store.all(:record_1).find { _1.id == "id_1" }
      assert_equal "UPDATED", reloaded.name
    end

    def test_transaction
      tmpdir = Dir.mktmpdir

      store = Store.define do
        storage(:yaml, dir: tmpdir)

        record(:record) do
          attribute(:id)
          attribute(:attr)
        end
      end

      store.create(
        :record,
        id: "id_1",
        attr: "attr",
      )

      store.create(
        :record,
        id: "id_2",
        attr: "attr",
      )

      record_1, record_2 = store.all(:record)

      assert_equal 2, store.versions.count

      store.transaction do
        store.update(record_1, attr: "attr_updated")
        store.update(record_2, attr: "attr_updated")
      end

      assert_equal 3, store.versions.count
    end

    def test_transaction_rollback_on_error
      tmpdir = Dir.mktmpdir

      store = Store.define do
        storage(:yaml, dir: tmpdir)

        record(:record) do
          attribute(:id)
          attribute(:attr)
        end
      end

      store.create(:record, id: "id_1", attr: "original")
      assert_equal 1, store.versions.count

      begin
        store.transaction do
          record = store.all(:record).first
          store.update(record, attr: "updated")
          raise "Something went wrong"
        end
      rescue => e
        # Exception expected
      end

      # Version count should not change due to rollback
      assert_equal 1, store.versions.count

      # Record should still have original value
      record = store.all(:record).first
      assert_equal "original", record.attr
    end

    def test_transaction_preserves_concurrent_changes
      tmpdir = Dir.mktmpdir

      store = Store.define do
        storage(:yaml, dir: tmpdir)

        record(:record) do
          attribute(:id)
          attribute(:attr)
        end
      end

      store.create(:record, id: "id_1", attr: "original_1")
      store.create(:record, id: "id_2", attr: "original_2")
      store.create(:record, id: "id_3", attr: "original_3")

      assert_equal 3, store.versions.count

      # Get records before transaction
      record_1, record_2 = store.all(:record).take(2)

      # Start a transaction using the store interface
      store.transaction do
        store.update(record_1, attr: "transaction_1")
        store.update(record_2, attr: "transaction_2")

        # Before committing, simulate a concurrent update from another process
        # We can't actually do this in the test because the mutex prevents it,
        # but the implementation is designed to handle this by reading current
        # data at commit time and applying operations on top of it
      end

      # Transaction should create only one version
      assert_equal 4, store.versions.count

      # Both records should have their updated values
      records = store.all(:record).sort_by(&:id)
      assert_equal "transaction_1", records[0].attr
      assert_equal "transaction_2", records[1].attr
      assert_equal "original_3", records[2].attr
    end

    def test_transaction_applies_on_top_of_concurrent_file_changes
      tmpdir = Dir.mktmpdir

      store = Store.define do
        storage(:yaml, dir: tmpdir)

        record(:record) do
          attribute(:id)
          attribute(:attr)
        end
      end

      store.create(:record, id: "id_1", attr: "original_1")
      store.create(:record, id: "id_2", attr: "original_2")
      store.create(:record, id: "id_3", attr: "original_3")

      assert_equal 3, store.versions.count

      # Get records before transaction
      records = store.all(:record).sort_by(&:id)
      record_1, record_2, record_3 = records

      # Simulate what would happen with concurrent modifications:
      # Use transaction block, manually write a file (simulating another process)
      # during the transaction

      store.transaction do
        # Buffer some operations
        store.update(record_1, attr: "transaction_1")
        store.update(record_2, attr: "transaction_2")

        # Simulate concurrent write by manually writing a new version file
        # In the new structure, this means writing to versions/0003.yml and data.yml
        concurrent_data = {
          record: {
            "id_1" => { id: "id_1", attr: "original_1" },
            "id_2" => { id: "id_2", attr: "original_2" },
            "id_3" => { id: "id_3", attr: "concurrent_3" }
          }
        }.transform_keys(&:to_s)

        # Copy current data.yml to versions/0003.yml
        FileUtils.mkdir_p(File.join(tmpdir, "versions"))
        FileUtils.cp(File.join(tmpdir, "data.yml"), File.join(tmpdir, "versions", "0003.yml"))

        # Write new data to data.yml
        File.write(File.join(tmpdir, "data.yml"), concurrent_data.to_yaml)
      end

      assert_equal 5, store.versions.count

      # Transaction operations should be applied on top of the concurrent change
      records = store.all(:record).sort_by(&:id)
      assert_equal "transaction_1", records[0].attr  # Updated by transaction
      assert_equal "transaction_2", records[1].attr  # Updated by transaction
      assert_equal "concurrent_3", records[2].attr   # Updated by concurrent write, preserved
    end

    def test_concurrent_write_transaction

    end

    def test_restore
      tmpdir = Dir.mktmpdir

      store = Store.define do
        storage(:yaml, dir: tmpdir)

        record(:record) do
          attribute(:id)
          attribute(:value)
        end
      end

      # Create initial versions
      store.create(:record, id: "id_1", value: "v1")
      store.create(:record, id: "id_2", value: "v2")

      record_1 = store.all(:record).find { _1.id == "id_1" }
      store.update(record_1, value: "v1_updated")

      # Should have 3 versions now
      assert_equal 3, store.versions.count

      # Check file system before restore
      assert File.exist?(File.join(tmpdir, "data.yml"))
      assert File.exist?(File.join(tmpdir, "versions", "0001.yml"))
      assert File.exist?(File.join(tmpdir, "versions", "0002.yml"))

      # Verify data.yml has the updated data
      latest_data = YAML.load_file(File.join(tmpdir, "data.yml"))
      assert_equal "v1_updated", latest_data["record"]["id_1"]["value"]

      # Restore to version 1 (first create)
      restored_store = store.versions[0].restore

      # Should only have 2 versions after restore (version 1 becomes latest, version 2 still exists)
      assert_equal 2, restored_store.versions.count

      # Check file system after restore
      assert File.exist?(File.join(tmpdir, "data.yml"))
      assert File.exist?(File.join(tmpdir, "versions", "0001.yml"))
      refute File.exist?(File.join(tmpdir, "versions", "0002.yml")), "Version 0002.yml should be deleted after restore"

      # Verify data.yml now has version 1 data
      latest_data = YAML.load_file(File.join(tmpdir, "data.yml"))
      assert_equal "v1", latest_data["record"]["id_1"]["value"]
      refute latest_data["record"].key?("id_2"), "id_2 should not exist in version 1"

      # Verify we can read the correct data
      records = restored_store.all(:record)
      assert_equal 1, records.count
      assert_equal "id_1", records[0].id
      assert_equal "v1", records[0].value

      # Verify we can continue working after restore
      restored_store.create(:record, id: "id_3", value: "v3")
      assert_equal 3, restored_store.versions.count

      # Check file system after new create
      assert File.exist?(File.join(tmpdir, "data.yml"))
      assert File.exist?(File.join(tmpdir, "versions", "0001.yml"))
      assert File.exist?(File.join(tmpdir, "versions", "0002.yml"))

      # Verify data.yml has both id_1 and id_3
      latest_data = YAML.load_file(File.join(tmpdir, "data.yml"))
      assert_equal "v1", latest_data["record"]["id_1"]["value"]
      assert_equal "v3", latest_data["record"]["id_3"]["value"]
      assert_equal 2, latest_data["record"].keys.count
    end

    def test_where_with_lambda_filter
      tmpdir = Dir.mktmpdir

      store = Store.define do
        storage(:yaml, dir: tmpdir)

        record(:record) do
          attribute(:id)
          attribute(:value)
        end
      end

      store.create(:record, id: "id_1", value: 2)
      store.create(:record, id: "id_2", value: 3)
      store.create(:record, id: "id_3", value: 4)
      store.create(:record, id: "id_4", value: 5)

      # Test with lambda that filters even values
      even_records = store.where(:record, value: ->(v) { v.even? })
      assert_equal 2, even_records.count
      assert_equal [2, 4], even_records.map(&:value).sort

      # Test with lambda that filters odd values
      odd_records = store.where(:record, value: ->(v) { v.odd? })
      assert_equal 2, odd_records.count
      assert_equal [3, 5], odd_records.map(&:value).sort

      # Test combining lambda with regular value filter
      even_with_id_filter = store.where(:record, id: "id_3", value: ->(v) { v.even? })
      assert_equal 1, even_with_id_filter.count
      assert_equal "id_3", even_with_id_filter.first.id
      assert_equal 4, even_with_id_filter.first.value
    end
  end
end
