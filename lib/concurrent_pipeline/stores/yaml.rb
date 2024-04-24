# frozen_string_literal: true

require "securerandom"
require "yaml"

require_relative "yaml/db"
require_relative "yaml/history"

module ConcurrentPipeline
  module Stores
    module Yaml
      def self.build_writer(data:, dir:, registry:)
        data_path = File.join(dir, "data.yml")
        versions_path = File.join(dir, "versions.yml")

        after_apply = ->(changesets) do
          File.write(data_path, data.to_yaml)
          File.open(versions_path, "a") do |f|
            changesets
              .map { _1.as_json.to_yaml }
              .join("\n")
              .then { f.puts(_1)}
          end
        end

        db = Db.new(data: data, registry: registry, after_apply: after_apply)

        changeset = db.changeset
        changeset.deltas << Changeset::InitialDelta.new(data: data)
        db.apply(changeset)
        db
      end

      def self.history(dir:, registry:)
        path = File.join(dir, "versions.yml")
        History.new(registry: registry, path: path)
      end
    end
  end
end
