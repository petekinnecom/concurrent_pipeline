# frozen_string_literal: true

require "open3"

module ConcurrentPipeline
  class Shell
    Error = Class.new(StandardError)
    class << self
      Result = Struct.new(:command, :success, :stdout, :stderr, keyword_init: true) do
        def success?
          success
        end
      end

      def run!(...)
        # only returns stdout just because.
        run(...)
          .tap { raise "command failed: \n#{_1.inspect}" unless _1.success? }
          .stdout
      end

      def run(command)
        Open3.popen3(command) do |_in, stdout, stderr, wait_thr|
          process_stdout = []
          stdout_thr = Thread.new do
            while line = stdout.gets&.chomp
              yield(:stdout, line) if block_given?
              process_stdout << line
            end
          end

          process_stderr = []
          stderr_thr = Thread.new do
            while line = stderr.gets&.chomp
              yield(:stderr, line) if block_given?
              process_stderr << line
            end
          end

          [
            stderr_thr,
            stdout_thr,
          ].each(&:join)

          Result.new(
            command: command,
            success: wait_thr.value.success?,
            stdout: process_stdout.join("\n"),
            stderr: process_stderr.join("\n"),
          )
        end
      end
    end
  end
end
