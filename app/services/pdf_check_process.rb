class PdfCheckProcess
  Unavailable = Class.new(StandardError)
  Result = Data.define(:status, :output)
  MAX_OUTPUT_BYTES = 32 * 1024

  def initialize(wall_seconds: 3, cpu_seconds: 2, memory_bytes: 512 * 1024 * 1024)
    @wall_seconds, @cpu_seconds, @memory_bytes = wall_seconds, cpu_seconds, memory_bytes
  end

  def call(*command)
    reader, writer = IO.pipe
    limits = { rlimit_cpu: [ @cpu_seconds, @cpu_seconds ], rlimit_core: [ 0, 0 ] }
    if RUBY_PLATFORM.include?("linux")
      limits[:rlimit_as] = [ @memory_bytes, @memory_bytes ]
    elsif RUBY_PLATFORM.include?("darwin")
      memory_reader = MacProcessMemory
    else
      raise Unavailable, "unsupported_platform"
    end
    deadline = monotonic_time + @wall_seconds
    pid = Process.spawn(*command, in: File::NULL, out: writer, err: writer, pgroup: true, **limits)
    writer.close
    output = +"".b
    loop do
      drain(reader, output)
      finished = Process.waitpid2(pid, Process::WNOHANG)
      if finished
        pid = nil
        drain(reader, output)
        return Result.new(status: finished.last, output: output)
      end
      raise Unavailable, "parser_timeout" if monotonic_time >= deadline
      if memory_reader && (rss = memory_reader.bytes(pid)) && rss > @memory_bytes
        raise Unavailable, "parser_memory_limit"
      end
      sleep 0.01
    end
  rescue SystemCallError, IOError, LoadError => error
    raise Unavailable, "parser_runtime_#{error.class.name}"
  ensure
    if pid
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
    end
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  private

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def drain(reader, output)
    loop do
      chunk = reader.read_nonblock(4096, exception: false)
      return if chunk.nil? || chunk == :wait_readable

      output << chunk
      raise Unavailable, "parser_output_limit" if output.bytesize > MAX_OUTPUT_BYTES
    end
  end
end
