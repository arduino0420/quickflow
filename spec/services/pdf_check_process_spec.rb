require "rails_helper"

RSpec.describe PdfCheckProcess do
  def fake_parser(source)
    Dir.mktmpdir("qpdf-process-spec") do |directory|
      path = File.join(directory, "parser")
      File.write(path, "#!#{RbConfig.ruby}\n#{source}\n")
      File.chmod(0o700, path)
      yield path
    end
  end

  it "kills and reaps a parser at the wall deadline" do
    fake_parser("sleep 30") do |path|
      child = nil
      allow(Process).to receive(:spawn).and_wrap_original do |original, *arguments, **options|
        child = original.call(*arguments, **options)
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { described_class.new(wall_seconds: 0.1).call(path) }.to raise_error(described_class::Unavailable, "parser_timeout")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
      expect { Process.kill(0, child) }.to raise_error(Errno::ESRCH)
    end
  end

  it "bounds diagnostics rather than accumulating arbitrary parser output" do
    fake_parser("STDOUT.sync=true; loop { puts 'x'*4096 }") do |path|
      expect { described_class.new.call(path) }.to raise_error(described_class::Unavailable, "parser_output_limit")
    end
  end

  it "contains CPU exhaustion in the child" do
    fake_parser("loop {}") do |path|
      result = described_class.new(wall_seconds: 4, cpu_seconds: 1).call(path)
      expect(result.status).not_to be_success
    end
  end

  it "bounds memory without applying unsupported Darwin address-space limits" do
    fake_parser('a=[]; loop { a << "x"*1048576; sleep 0.005 }') do |path|
      runner = described_class.new(wall_seconds: 4, memory_bytes: 64 * 1024 * 1024)
      if RUBY_PLATFORM.include?("darwin")
        expect { runner.call(path) }.to raise_error(described_class::Unavailable, "parser_memory_limit")
      else
        expect(runner.call(path).status).not_to be_success
      end
    end
  end
end
