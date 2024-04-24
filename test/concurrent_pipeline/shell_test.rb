# frozen_string_literal: true

require "test_helper"

module ConcurrentPipeline
  class ShellTest < Test
    def test_run_successful_command
      result = Shell.run("echo 'hello world'")

      assert result.success?
      assert_equal "hello world", result.stdout
      assert_equal "", result.stderr
      assert_equal "echo 'hello world'", result.command
    end

    def test_run_failing_command
      result = Shell.run("exit 1")

      refute result.success?
      assert_equal "", result.stdout
      assert_equal "", result.stderr
    end

    def test_run_command_not_found_raises_error
      assert_raises(Errno::ENOENT) do
        Shell.run("nonexistent_command_xyz")
      end
    end

    def test_run_with_multiline_stdout
      result = Shell.run("echo 'line1'; echo 'line2'; echo 'line3'")

      assert result.success?
      assert_equal "line1\nline2\nline3", result.stdout
    end

    def test_run_with_stderr
      result = Shell.run("echo 'error message' >&2")

      assert result.success?
      assert_equal "", result.stdout
      assert_equal "error message", result.stderr
    end

    def test_run_with_both_stdout_and_stderr
      result = Shell.run("echo 'output'; echo 'error' >&2")

      assert result.success?
      assert_equal "output", result.stdout
      assert_equal "error", result.stderr
    end

    def test_run_with_block_yields_stdout
      yielded_lines = []

      result = Shell.run("echo 'line1'; echo 'line2'") do |stream, line|
        yielded_lines << [stream, line] if stream == :stdout
      end

      assert result.success?
      assert_equal [[:stdout, "line1"], [:stdout, "line2"]], yielded_lines
      assert_equal "line1\nline2", result.stdout
    end

    def test_run_with_block_yields_stderr
      yielded_lines = []

      result = Shell.run("echo 'error1' >&2; echo 'error2' >&2") do |stream, line|
        yielded_lines << [stream, line] if stream == :stderr
      end

      assert result.success?
      assert_equal [[:stderr, "error1"], [:stderr, "error2"]], yielded_lines
      assert_equal "error1\nerror2", result.stderr
    end

    def test_run_with_block_yields_both_streams
      yielded_lines = []

      result = Shell.run("echo 'out1'; echo 'err1' >&2; echo 'out2'") do |stream, line|
        yielded_lines << [stream, line]
      end

      assert result.success?

      # Extract stdout and stderr separately
      stdout_lines = yielded_lines.select { |s, _| s == :stdout }.map(&:last)
      stderr_lines = yielded_lines.select { |s, _| s == :stderr }.map(&:last)

      assert_equal ["out1", "out2"], stdout_lines
      assert_equal ["err1"], stderr_lines
    end

    def test_run_bang_successful_command
      stdout = Shell.run!("echo 'success'")

      assert_equal "success", stdout
    end

    def test_run_bang_failing_command_raises_error
      error = assert_raises(RuntimeError) do
        Shell.run!("exit 1")
      end

      assert_match(/command failed/, error.message)
    end

    def test_run_bang_returns_only_stdout
      # Verify that run! returns only stdout, not the full Result object
      output = Shell.run!("echo 'output'; echo 'error' >&2")

      assert_kind_of String, output
      assert_equal "output", output
    end

    def test_run_bang_with_block
      yielded_lines = []

      stdout = Shell.run!("echo 'line1'; echo 'line2'") do |stream, line|
        yielded_lines << [stream, line]
      end

      assert_equal "line1\nline2", stdout
      assert_equal [[:stdout, "line1"], [:stdout, "line2"]], yielded_lines
    end

    def test_result_struct_success_predicate
      success_result = Shell.run("echo 'test'")
      failure_result = Shell.run("exit 1")

      assert success_result.success?
      refute failure_result.success?
    end

    def test_result_struct_attributes
      result = Shell.run("echo 'output'")

      assert_respond_to result, :command
      assert_respond_to result, :success
      assert_respond_to result, :stdout
      assert_respond_to result, :stderr
      assert_respond_to result, :success?
    end

    def test_run_with_complex_command
      result = Shell.run("for i in 1 2 3; do echo $i; done")

      assert result.success?
      assert_equal "1\n2\n3", result.stdout
    end

    def test_run_with_piped_command
      result = Shell.run("echo 'hello\nworld' | grep hello")

      assert result.success?
      assert_equal "hello", result.stdout
    end

    def test_run_empty_output
      result = Shell.run("true")

      assert result.success?
      assert_equal "", result.stdout
      assert_equal "", result.stderr
    end
  end
end
