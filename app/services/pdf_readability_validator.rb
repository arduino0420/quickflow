# A bounded readability preflight, not a conformance or rendering guarantee.
# qpdf may recover in memory; warning-only files pass and original bytes are kept.
class PdfReadabilityValidator
  InvalidPdf = Class.new(StandardError)
  Unavailable = PdfCheckProcess::Unavailable
  INPUT_ERRORS = [
    "invalid password",
    "unable to find /Root dictionary",
    "unable to find trailer dictionary while recovering damaged file",
    "unable to find any pages while recovering damaged file"
  ].freeze

  def self.validate!(io)
    new.validate!(io)
  end

  def initialize(binary: Rails.root.join("vendor/qpdf/bin/qpdf").to_s, process: PdfCheckProcess.new)
    @binary, @process = binary, process
  end

  def validate!(io)
    position = io.pos
    path = File.expand_path(io.path)
    result = @process.call(@binary, "--check", path)
    return true if result.status.exited? && [ 0, 3 ].include?(result.status.exitstatus)

    # qpdf also uses exit 2 for I/O and internal failures. Only these exact,
    # regression-tested fatal diagnostics from the pinned release identify bad
    # input. Never classify warnings or expose diagnostics containing PDF data.
    if result.status.exited? && result.status.exitstatus == 2
      lines = result.output.lines.map(&:chomp)
      input_error = INPUT_ERRORS.any? { |message| lines.last == "qpdf: #{path}: #{message}".b } ||
        lines.last(2) == [ "ERROR: file does not contain any pages", "qpdf: errors detected" ]
      raise InvalidPdf, "invalid_pdf" if input_error
    end
    raise Unavailable, "parser_failed"
  rescue IOError, SystemCallError => error
    raise Unavailable, "parser_input_#{error.class.name}"
  ensure
    io.seek(position) if position
  end
end
