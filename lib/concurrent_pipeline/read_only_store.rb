# frozen_string_literal: true

module ConcurrentPipeline
  class ReadyOnlyStore
    attr_reader :store
    def initialize(store)
      @store = store
    end

    def find(...)
      store.find(...)
    end

    def all(...)
      store.all(...)
    end

    def everything(...)
      store.everything(...)
    end
  end
end
