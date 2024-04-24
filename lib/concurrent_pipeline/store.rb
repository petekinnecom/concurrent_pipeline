# frozen_string_literal: true

module ConcurrentPipeline
  class Store
    attr_reader :db, :changeset
    def initialize(db:, changeset:)
      @changeset = changeset
      @db = db
    end

    def find(...)
      db.find(...)
    end

    def all(...)
      db.find(...)
    end

    def create(...)
      changeset.create(...)
    end

    def update(...)
      changeset.update(...)
    end
  end
end
