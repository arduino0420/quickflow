require "rails_helper"
require "open3"

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
    expect { described_class.new.call("/usr/bin/yes", "x" * 4096) }
      .to raise_error(described_class::Unavailable, "parser_output_limit")
  end

  it "fails closed before spawning on two consecutive Mac monitor loader failures" do
    require "fiddle/import"
    fresh_monitor = Class.new(MacProcessMemory)
    stub_const("MacProcessMemory", fresh_monitor)
    stub_const("RUBY_PLATFORM", "x86_64-darwin")
    expect(Fiddle).to receive(:dlopen).with("/usr/lib/libproc.dylib").twice
      .and_raise(Fiddle::DLError, "private native-loader details")
    expect(Process).not_to receive(:spawn)
    2.times do
      expect { described_class.new.call("/unused/parser") }
        .to raise_error(described_class::Unavailable, "memory_monitor_unavailable")
    end
  end

  it "cleans its own remaining descendant group after the direct parser exits successfully" do
    source = <<~RUBY
      ready, signal = IO.pipe
      child = fork do
        ready.close
        STDOUT.close
        STDERR.close
        signal.write('ready')
        signal.close
        sleep 30
      end
      signal.close
      ready.read(5)
      File.write(ARGV.fetch(0), child.to_s)
      exit 0
    RUBY
    fake_parser(source) do |path|
      pidfile = "#{path}.child"
      result = described_class.new.call(path, pidfile)
      expect(result.status).to be_success
      child = Integer(File.read(pidfile))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        state, = Open3.capture2("/bin/ps", "-o", "stat=", "-p", child.to_s)
        # Orphans are reaped by the OS parent; neither live nor sleeping work may remain.
        break if state.strip.empty? || state.strip.start_with?("Z")

        raise "Parser descendant is still alive" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
    ensure
      begin
        if child && result && Process.getpgid(child) == result.status.pid
          Process.kill("KILL", -result.status.pid)
        end
      rescue Errno::ESRCH
        nil
      end
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
