# frozen_string_literal: true

require_relative "concurrent_pipeline/version"
require_relative "concurrent_pipeline/model"
require_relative "concurrent_pipeline/pipeline"
require_relative "concurrent_pipeline/producer"
require_relative "concurrent_pipeline/shell"

require "logger"

module ConcurrentPipeline
  class Error < StandardError; end
  # Your code goes here...
  Log = Logger.new($stdout).tap { _1.level = Logger::WARN }
end
