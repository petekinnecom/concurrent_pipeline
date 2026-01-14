module ConcurrentPipeline
  module Errors
    Base = Class.new(StandardError)
    AssertionFailure = Class.new(Base)
  end
end
