# Darwin does not support a useful RLIMIT_AS. Sample our own child with libproc;
# this is a best-effort RSS watchdog, not a hard allocation limit.
class MacProcessMemory
  if RUBY_PLATFORM.include?("darwin")
    require "fiddle/import"

    module Libproc
      extend Fiddle::Importer
      dlload "/usr/lib/libproc.dylib"
      extern "int proc_pidinfo(int, int, unsigned long long, void*, int)"
    end
  end

  def self.bytes(pid)
    # Apple's proc_taskinfo: 6 uint64_t + 12 int32_t; resident size is field 2.
    buffer = Fiddle::Pointer.malloc(96, Fiddle::RUBY_FREE)
    count = Libproc.proc_pidinfo(pid, 4, 0, buffer, 96) # PROC_PIDTASKINFO
    return buffer[8, 8].unpack1("Q") if count == 96
    return nil if Fiddle.last_error == Errno::ESRCH::Errno

    raise PdfCheckProcess::Unavailable, "memory_monitor_unavailable"
  end
end
