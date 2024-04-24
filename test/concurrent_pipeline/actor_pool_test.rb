# frozen_string_literal: true

require "test_helper"
require "ostruct"

module ConcurrentPipeline
  class ActorPoolTest < Minitest::Test
    class ActorPool
      attr_reader :pool
      def initialize(concurrency)
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
          puts "self.class: #{self.class}"
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

    def test_pool
      pool = ActorPool.new(1)

      start_time = Time.now.to_i

      10
        .times
        .map { |i|
          Thread.new {
            pool.process([-> { puts "hi: #{i}"; sleep 1 }])
          }
        }.map(&:join)

      elapsed_time = Time.now.to_i - start_time

      assert elapsed_time < 4
    end
  end
end
