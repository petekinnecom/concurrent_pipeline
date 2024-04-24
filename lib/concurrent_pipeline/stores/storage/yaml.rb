module ConcurrentPipeline
  module Stores
    module Storage
      class Yaml
        attr_reader :fs, :version_number

        def initialize(dir:, version_number: nil)
          @fs = Fs.new(dir: dir)
          @version_number = version_number
        end

        def in_transaction?
          !transaction_operations.nil?
        end

        def transaction(&block)
          begin_transaction
          begin
            yield
            commit_transaction
          rescue => e
            rollback_transaction
            raise e
          end
        end

        def create(name:, attrs:)
          in_txn = in_transaction?

          raise "Cannot write to non-current version" unless writeable?

          id = attrs[:id] || attrs["id"]
          raise "Record must have an id" unless id

          # Always buffer the operation
          buffer_operation(
            type: :create,
            name: name.to_s,
            id: id.to_s,
            attrs: attrs.transform_keys(&:to_s)
          )

          # Flush immediately if not in a transaction
          flush_buffer unless in_txn
        end

        def update(name:, id:, attrs:)
          in_txn = in_transaction?

          raise "Cannot write to non-current version" unless writeable?

          # Always buffer the operation
          buffer_operation(
            type: :update,
            name: name.to_s,
            id: id.to_s,
            attrs: attrs.transform_keys(&:to_s)
          )

          # Flush immediately if not in a transaction
          flush_buffer unless in_txn
        end

        def all(name:)
          data = load_data
          records = data[name.to_s] || {}
          records.values.map { |attrs| attrs.transform_keys(&:to_sym) }
        end

        def versions
          current_ver = current_version_number
          (1..current_ver).map { |idx| self.class.new(dir: fs.dir, version_number: idx) }
        end

        def restore
          current_version = version_number || current_version_number

          # Delete all versions after this one
          fs.version_files.each_with_index do |file, idx|
            version_num = idx + 1
            if version_num > current_version
              fs.delete_version(version_num)
            end
          end

          # If restoring to a historical version (not current), move it to latest.yml
          if version_number && version_number < current_version_number
            fs.restore_version(version_number)
          end

          # Return a new writeable storage at this version
          self.class.new(dir: fs.dir)
        end

        def writeable?
          version_number.nil? || version_number == current_version_number
        end

        private

        def begin_transaction
          raise "Transaction already in progress" if transaction_operations

          self.transaction_operations = []
        end

        def commit_transaction
          raise "No transaction in progress" unless transaction_operations

          flush_buffer
        end

        def rollback_transaction
          self.transaction_operations = nil
        end

        TRANSACTION_KEY = :yaml_storage_transaction_operations

        def transaction_operations
          Fiber[TRANSACTION_KEY]
        end

        def transaction_operations=(value)
          Fiber[TRANSACTION_KEY] = value
        end

        def buffer_operation(op)
          # If in a transaction, append to the transaction buffer
          if transaction_operations
            transaction_operations << op
          else
            # If not in a transaction, initialize a temporary buffer
            self.transaction_operations = [op]
          end
        end

        def flush_buffer
          return unless transaction_operations

          # Load current data and apply all buffered operations
          data = load_current_data
          transaction_operations.each do |op|
            apply_operation(data, op)
          end

          write_new_version(data)
          self.transaction_operations = nil
        end

        def apply_operation(data, op)
          case op[:type]
          when :create
            data[op[:name]] ||= {}
            data[op[:name]][op[:id]] = op[:attrs]
          when :update
            records = data[op[:name]] || {}
            if records[op[:id]]
              records[op[:id]].merge!(op[:attrs])
            else
              raise "Record not found: #{op[:name]} with id #{op[:id].inspect}"
            end
          end
        end

        def load_current_data
          load_data
        end

        def load_data
          if version_number
            # Reading a historical version from the versions/ directory
            target_version = version_number
            fs.read_version(target_version)
          else
            # Reading the current latest.yml
            current_ver = current_version_number
            if current_ver == 0
              {}
            else
              fs.read_version(current_ver)
            end
          end
        end

        def write_new_version(data)
          next_version = current_version_number + 1
          fs.write_version(next_version, data)
        end

        def current_version_number
          fs.current_version_number
        end
      end
    end
  end
end
