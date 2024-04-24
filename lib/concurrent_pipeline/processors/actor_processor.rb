# frozen_string_literal: true

require "concurrent/edge/erlang_actor"

require_relative "../changeset"
require_relative "../read_only_store"

module ConcurrentPipeline
  module Processors
    class ActorProcessor
      Message = Struct.new(:type, :payload) do
        def to_s(...)
          inspect(...)
        end
        def inspect(...)
          "<Message #{type} (#{payload.class}) >"
        end
      end

      Ms = Module.new do
        def self.g(...)
          Message.new(...)
        end

        def msg(...)
          Message.new(...)
        end
      end

      Msg = Message.method(:new) #->(*args, **opts) { Message.new(*args, **opts) }

      def self.call(...)
        new(...).call
      end

      attr_reader :store, :pipelineables, :registry, :stream
      def initialize(store:, pipelineables:, registry:, stream:)
        @store = store
        @pipelineables = pipelineables
        @registry = registry
        @stream = stream
      end

      module PipeActor
        module InstanceMethods
          attr_accessor :ctx
          def respond(msg)
            if self.class.on_blocks.key?(msg.type)
              instance_exec(msg, &self.class.on_blocks[msg.type])
            else
              instance_exec(msg, &self.class.default_block)
            end
          rescue => e
            Log.warn("error: #{e.class}:#{e.message}\n---\n#{e.backtrace.join("\n")}")
            terminate :error
          end

          def reply(...)
            ctx.reply(...)
          end

          def terminate(...)
            ctx.terminate(...)
          end
        end

        def self.extended(base)
          base.include(InstanceMethods)
        end

        def spawn(...)
          instance = self.new(...)
          Concurrent::ErlangActor.spawn(type: :on_pool) do
            receive(keep: true) do |msg|
              instance.ctx = self
              instance.respond(msg)
            end
          end
        end

        def on_blocks
          @on_blocks ||= {}
        end

        def default_block
          @default_block
        end

        private

        def on(type, &block)
          on_blocks[type] = block
        end

        def default(&block)
          @default_block = block
        end
      end

      class ActorPool
        attr_reader :pool
        def initialize(concurrency = 10000)
          @pool = Pool.spawn(concurrency)
        end

        def process(bodies)
          # This can be blocking because it is called by perform
          # which is already being called by an actor, so blocking is ok.
          # However, we still want the pool to be limited in size across
          # all actors.
          bodies.map { |body|
            pool.ask(
              Processors::ActorProcessor::Message.new(
                :queue,
                body
              )
            )
          }.map { _1.terminated.value! }
        end

        class Pool
          extend Processors::ActorProcessor::PipeActor
          attr_reader :concurrency, :queue, :processing_count
          def initialize(concurrency= 10000)
            @concurrency = concurrency
            @queue = []
            @processing_count = 0
          end

          on :queue do |msg|
            pid = spawn_queued_actor(msg.payload)
            queue << pid
            try_process
            reply(pid)
          end

          on :finished do |msg|
            @processing_count -= 1
            try_process()
          end

          private

          def try_process
            return if queue.empty?
            return if processing_count >= concurrency

            @processing_count += 1
            pid = queue.shift
            pid.tell(ctx.pid)
          end

          def spawn_queued_actor(body)
            Concurrent::ErlangActor.spawn(type: :on_pool) do
              receive do |sender|
                # begin
                body.call

                sender.tell(Processors::ActorProcessor::Message.new(:finished, nil))
              end
            end
          end
        end
      end

      class Changeset
        extend PipeActor

        attr_reader :dispatch, :pipelines, :store
        def initialize(dispatch:, store:)
          @dispatch = dispatch
          @store = store
          @pipelines = []
        end

        on :changeset do |msg|
          pipelines << msg.payload
        end

        on :flush_queue do |msg|
          next unless pipelines.any?

          diffed = store.apply(pipelines.map(&:changeset))
          if diffed
            dispatch.tell(Msg.(:pipelines_updated, pipelines.map(&:id)))
          else
            dispatch.tell(Msg.(:pipelines_processed, pipelines.map(&:id)))
          end

          @pipelines = []
        end
      end

      class Scheduler
        extend PipeActor

        attr_reader :dispatch, :status, :store, :pipelineables, :stream
        def initialize(dispatch:, store:, pipelineables:, stream:)
          @dispatch = dispatch
          @store = store
          @pipelineables = pipelineables
          @stream = stream
          @status = {}
          @unlimited_pool = ActorPool.new
          @pools = {}
        end

        def pool_for(pipelineable)
          @pools[pipelineable] ||= (
            if pipelineable.concurrency
              ActorPool.new(pipelineable.concurrency)
            else
              @unlimited_pool
            end
          )
        end

        default do |msg|
          # we update pipeline_ids on both messages.
          pipeline_ids = msg.payload || []
          pipeline_ids.each do |pipeline_id|
            status[pipeline_id] = :processed
          end

          case msg.type
          when :requeue
            reader = store.reader

            pipelineables
              .map { _1.build_pipelines(store: reader, stream: stream, pool: pool_for(_1)) }
              .flatten
              .each do |c|
                if status[c.id] != :queued && c.should_perform?
                  Log.debug("enqueuing: #{c.id}")
                  status[c.id] = :queued
                  dispatch.tell(Msg.(:enqueue, c))
                end
              end
          end

          if status.values.all? { _1 == :processed }
            dispatch.tell(Msg.(:all_pipelines_processed))
          end
          reply :ok
        end
      end

      class Ticker
        extend PipeActor

        attr_reader :dispatch
        def initialize(dispatch)
          @dispatch = dispatch
        end

        on :start do |msg|
          loop do
            sleep 0.1
            dispatch.tell(Msg.(:tick))
          end
        end
      end

      class Dispatch
        extend PipeActor

        attr_reader :work, :changeset, :scheduler

        on :init do |msg|
          @work = msg.payload[:work]
          @changeset = msg.payload[:changeset]
          @scheduler = msg.payload[:scheduler]
          reply :ok
        end

        on :tick do |msg|
          changeset.tell(Msg.(:flush_queue))
        end

        on :enqueue do |msg|
          work.tell(Msg.(:process, msg.payload))
        end

        on :error do |msg|
          warn "error: #{msg.payload.class}:#{msg.payload.message}\n---\n#{msg.payload.backtrace.join("\n")}"
          terminate :error
        end

        on :all_pipelines_processed do |msg|
          terminate :ok
        end

        on :pipelines_updated do |msg|
          scheduler.tell(Msg.(:requeue, msg.payload))
        end

        on :pipelines_processed do |msg|
          scheduler.tell(Msg.(:pipelines_processed, msg.payload))
        end

        on :changeset do |msg|
          changeset.tell(Msg.(:changeset, msg.payload))
        end

        default do |msg|
          Log.debug("unknown message: #{msg.inspect}")
        end
      end

      class Work
        extend PipeActor

        attr_reader :dispatch
        def initialize(dispatch)
          @dispatch = dispatch
        end

        on :process do |msg|
          a = Concurrent::ErlangActor.spawn(type: :on_pool) do
            receive do |pipeline, dispatch|
              pipeline = msg.payload
              Log.debug("starting perform: #{pipeline.class}: #{pipeline.id}")
              pipeline.perform
              Log.debug("finished perform: #{pipeline.class}: #{pipeline.id}")
              dispatch.tell(Msg.(:changeset, pipeline))
            rescue => e
              dispatch.tell(Msg.(:error, e))
            end
          end

          a.tell([msg.payload, dispatch])
        end
      end

      def call
        dispatch = Dispatch.spawn
        ticker = Ticker.spawn(dispatch)
        work = Work.spawn(dispatch)
        changeset = Changeset.spawn(dispatch: dispatch, store: store)
        scheduler = Scheduler.spawn(
          dispatch: dispatch,
          store: store,
          pipelineables: pipelineables,
          stream: stream
        )

        dispatch.tell(Msg.(
          :init,
          work: work,
          changeset: changeset,
          scheduler: scheduler
        ))

        Log.debug("triggering initial queue")

        ticker.tell(Msg.(:start))
        scheduler.tell(Msg.(:requeue))

        dispatch.terminated.result
      end
    end
  end
end
