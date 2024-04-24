require "yaml"
require "fileutils"

module ConcurrentPipeline
  module Stores
    module Storage
      class Yaml
        class Fs
          @@mutex = Mutex.new

          attr_reader :dir

          def initialize(dir:)
            @dir = dir
            FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
            FileUtils.mkdir_p(versions_dir) unless Dir.exist?(versions_dir)
          end

          def read_version(version_number)
            @@mutex.synchronize do
              if version_number == 0
                {}
              else
                current_ver = unsafe_current_version_number

                # If requesting the current/latest version, read from latest.yml
                if version_number == current_ver
                  if File.exist?(latest_file_path)
                    data = File.read(latest_file_path).then { YAML.load(_1, aliases: true) || {} }
                    # Normalize keys: convert record names and ID keys to strings for consistency
                    data.transform_keys(&:to_s).transform_values do |records|
                      records.transform_keys(&:to_s)
                    end
                  else
                    {}
                  end
                else
                  # Reading a historical version from versions/ directory
                  file_path = version_file_path(version_number)
                  if File.exist?(file_path)
                    data = File.read(file_path).then { YAML.load(_1, aliases: true) || {} }
                    # Normalize keys: convert record names and ID keys to strings for consistency
                    data.transform_keys(&:to_s).transform_values do |records|
                      records.transform_keys(&:to_s)
                    end
                  else
                    {}
                  end
                end
              end
            end
          end

          def write_version(version_number, data)
            @@mutex.synchronize do
              # Copy current latest.yml to versions directory if it exists
              if File.exist?(latest_file_path)
                current_version = unsafe_current_version_number
                if current_version > 0
                  version_path = version_file_path(current_version)
                  FileUtils.cp(latest_file_path, version_path)
                end
              end

              # Write new data to latest.yml
              File.write(latest_file_path, YAML.dump(data))
            end
          end

          def current_version_number
            @@mutex.synchronize do
              unsafe_current_version_number
            end
          end

          def version_files
            @@mutex.synchronize do
              unsafe_version_files
            end
          end

          def delete_version(version_number)
            @@mutex.synchronize do
              current_ver = unsafe_current_version_number

              # If deleting the latest version
              if version_number == current_ver
                File.delete(latest_file_path) if File.exist?(latest_file_path)
              else
                # Deleting an archived version
                file_path = version_file_path(version_number)
                File.delete(file_path) if File.exist?(file_path)
              end
            end
          end

          def restore_version(version_number)
            @@mutex.synchronize do
              version_path = version_file_path(version_number)

              if File.exist?(version_path)
                # Copy the version file to latest.yml
                FileUtils.cp(version_path, latest_file_path)
              else
                raise "Version #{version_number} does not exist"
              end
            end
          end

          private

          def unsafe_current_version_number
            if File.exist?(latest_file_path)
              # Count existing version files + 1 for the latest
              unsafe_version_files.length + 1
            else
              0
            end
          end

          def unsafe_version_files
            Dir.glob(File.join(versions_dir, "*.yml")).sort
          end

          def version_file_path(version_num)
            File.join(versions_dir, "%04d.yml" % version_num)
          end

          def latest_file_path
            File.join(dir, "data.yml")
          end

          def versions_dir
            File.join(dir, "versions")
          end
        end
      end
    end
  end
end
