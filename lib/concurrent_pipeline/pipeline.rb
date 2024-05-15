require "time"

module ConcurrentPipeline
  class Pipeline

    # {
    #   type: PipelineStep,
    #   pipeline_id: [MyPipeline, :vhost, 1],
    #   name: {string},
    #   result: nil | :success | :failure,
    #   completed_at: nil | {timestamp},
    #   sequence: 3
    # }

    class PipelineStep
      extend Model

      attribute :id
      attribute :pipeline_id
      attribute :name
      attribute :result
      attribute :completed_at
      attribute :sequence
      attribute :error_message

      def success?
        result == :success
      end
    end

    class Wrapper
      attr_reader :pipeline, :pool
      def initialize(pipeline:, pool:)
        @pipeline = pipeline
        @pool = pool
      end

      def id
        pipeline_id = (
          if pipeline.class.target_type
            pipeline.target.id
          end
        )

        [pipeline.class.name, pipeline_id].compact.join("__")
      end

      def perform
        if pipeline_steps.empty?
          create_pipeline_steps
        else
          pipeline_steps
            .reject(&:completed_at)
            .group_by(&:sequence)
            .values
            .first
            .map { |step|
              wrapper = self
              -> () do
                begin
                  wrapper.pipeline.public_send(step.name)
                  wrapper.changeset.update(
                    step,
                    completed_at: Time.now.iso8601,
                    result: :success
                  )
                rescue => e
                  wrapper.changeset.update(
                    step,
                    completed_at: Time.now.iso8601,
                    result: :failure,
                    error: {class: e.class, message: e.message, backtrace: e.backtrace}
                  )
                end
              end
            }
          .then { pool.process(_1) }
        end
      end

      def should_perform?
        ready? && !done?
      end

      def create_pipeline_steps
        sequence = (
          if pipeline.respond_to?(:steps)
            pipeline.steps
          else
            [:perform]
          end
        )

        sequence.each_with_index do |sub_seq, i|
          Array(sub_seq).each do |step_name|
            changeset.create(
              PipelineStep,
              pipeline_id: id,
              name: step_name,
              sequence: i
            )
          end
        end
      end

      def pipeline_steps
        @pipeline_steps ||= (
          store
            .all(PipelineStep)
            .select { _1.pipeline_id == id }
            .sort_by(&:sequence)
        )
      end

      def ready?
        if pipeline.respond_to?(:ready?)
          pipeline.ready?
        else
          true
        end
      end

      def done?
        if pipeline.respond_to?(:done?)
          pipeline.done?
        else
          !pipeline_steps.empty? && pipeline_steps.all?(&:completed_at)
        end
      end

      def store
        pipeline.store
      end

      def changeset
        pipeline.changeset
      end

      def stream(type, payload = nil)
        pipeline.stream.push(type, payload = nil)
      end
    end

    class << self
      attr_reader(:target_type)

      def build_pipelines(store:, stream:, pool:)
        if target_type
          @target_proc.call(store).map { |record|
            Wrapper.new(
              pipeline: new(
                target: record,
                store: store,
                changeset: store.changeset,
                stream: stream
              ),
              pool: pool
            )
          }
        else
          Wrapper.new(
            pipeline: new(
              target: nil,
              store: store,
              changeset: store.changeset,
              stream: stream
            ),
            pool: pool
          )
        end
      end

      def each(type_or_proc, as: nil)
        if type_or_proc.is_a?(Symbol)
          @target_type = type_or_proc
          @target_proc = ->(store) { store.all(type_or_proc) }
        elsif type_or_proc.respond_to?(:call)
          @target_type = :custom
          @target_proc = type_or_proc
        end

        define_method(as) { target } if as
        define_method(:record) { target }
      end

      def ready(...)
        define_method(:ready?, ...)
      end

      def done(...)
        define_method(:done?, ...)
      end

      def perform(...)
        steps(:perform)
        define_method(:perform, ...)
      end

      def steps(*sequence)
        define_method(:steps) { sequence }
      end

      def concurrency(size = nil)
        @concurrency = size if size
        @concurrency
      end
    end

    attr_reader :target, :store, :changeset
    def initialize(target:, store:, changeset:, stream:)
      @target = target
      @store = store
      @changeset = changeset
      @stream = stream
    end

    def stream(type, payload)
      @stream.push(type, payload)
    end
  end
end
