# frozen_string_literal: true

require "tmpdir"

require_relative "processors/actor_processor"
require_relative "registry"
require_relative "store"
require_relative "stores/yaml"

module ConcurrentPipeline
  class Producer
    class Stream
      attr_reader :receivers
      def initialize
        @receivers = {
          default: -> (type, *) { Log.warn("No stream handler for type: #{type.inspect}") },
        }
      end

      def on(type, &block)
        receivers[type] = block
      end

      def push(type, payload)
        receivers[type]
          .tap { Log.warn("No stream handler for type: #{type.inspect}") if _1.nil? }
          &.call(payload)
      end
    end

    def initialize(data: nil, store: nil, stream: nil, dir: nil, &initialization_block)
      raise ArgumentError.new("provide data or store but not both") if data && store
      raise ArgumentError.new("must provide initial data, a store, or a block") unless data || store || initialization_block
      @dir = dir
      @data = data
      @store = store&.reader? ? store.store : store
      @initialization_block = initialization_block
      @stream = stream
    end

    def call(&block)
      changeset = self.store.changeset
      @initialization_block&.call(changeset)
      store.apply(changeset)

      Processors::ActorProcessor.call(
        store: store,
        pipelineables: pipelineables,
        registry: registry,
        stream: stream
      )

      store.reader.all(:PipelineStep).all?(&:success?)
    end

    def data
      store.reader.to_h
    end

    def store
      @store ||= self.class.store.build_writer(data: @data || {}, dir: dir, registry: registry)
    end

    def stream
      @stream || self.class.stream
    end

    def versions
      self.class.store.versions(dir: dir, registry: registry)
    end

    def history
      self.class.store.history(dir: dir, registry: registry)
    end

    def dir
      @dir ||= Dir.mktmpdir
    end

    private

    def registry
      self.class.registry
    end

    def pipelineables
      self.class.pipelineables
    end


    class << self
      def store(klass = nil)
        @store = klass || Stores::Yaml
        @store
      end

      def pipelineables
        @pipelineables ||= []
      end

      def registry
        @registry ||= (
          Registry
            .new
            .tap { _1.register(:PipelineStep, Pipeline::PipelineStep) }
        )
      end

      def model(klass_or_symbol, as: nil, &block)
        if klass_or_symbol.is_a?(Class)
          raise ArgumentError.new("Cannot provide both a class and a block") if block
          as ||= klass_or_symbol.name.split("::").last.to_sym
          registry.register(as, klass_or_symbol)
        elsif klass_or_symbol.is_a?(Symbol)
          registry.register(klass_or_symbol, Class.new do
            extend Model
            instance_eval(&block)
          end)
        else
          raise ArgumentError.new("Must provide either a class or a symbol")
        end
      end

      module CustomPipelines
      end

      def stream(&block)
        return @stream unless block
        @stream = Stream.new.tap { _1.instance_exec(&block) }
      end

      def pipeline(klass_or_symbol = nil, **opts, &block)
        pipelineable = (
          if klass_or_symbol.is_a?(Class)
            raise ArgumentError.new("Cannot provide both a class and a block") if block
            klass_or_symbol
          elsif klass_or_symbol.is_a?(Symbol) || klass_or_symbol.nil?
            klass_or_symbol ||= "Pipeline#{pipelineables.count}"
            pipeline_class = Class.new(Pipeline, &block)
            class_name = klass_or_symbol.to_s.split("_").collect(&:capitalize).join
            CustomPipelines.const_set(class_name, pipeline_class)
            pipeline_class
          else
            raise ArgumentError.new("Must provide either a class or a symbol")
          end
        )

        opts.each do |meth, args|
          pipelineable.public_send(meth, *Array(args))
        end

        pipelineables << pipelineable
      end
    end
  end
end
