require "rails_helper"
require_relative "../support/pdf_fixture_builder"

RSpec.describe PdfReadabilityValidator do
  include PdfFixtureBuilder

  def with_pdf(bytes)
    Tempfile.create([ "readability", ".pdf" ]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      file.seek(2)
      yield file
      expect(file.pos).to eq(2)
    end
  end

  %w[material.pdf pdf_preview.pdf pdf_preview_single.pdf pdf_preview_three.pdf pdf_preview_ten.pdf browser_answer.pdf readable_encrypted.pdf].each do |name|
    it "accepts #{name} with ordinary qpdf recovery and preserves IO position" do
      with_pdf(File.binread(Rails.root.join("spec/fixtures/files", name))) do |file|
        expect(described_class.validate!(file)).to be(true)
      end
    end
  end

  it "accepts a structurally valid PDF at the existing 25MiB boundary" do
    with_pdf(valid_pdf_bytes(size: 25 * 1024 * 1024)) { |file| expect(described_class.validate!(file)).to be(true) }
  end

  [ "%PDF-1.7\ninvalid", "%PDF-1.4\n".ljust(25 * 1024 * 1024, "\0") ].each_with_index do |bytes, index|
    it "rejects header-bearing broken input #{index} without moving IO" do
      with_pdf(bytes) { |file| expect { described_class.validate!(file) }.to raise_error(described_class::InvalidPdf) }
    end
  end

  it "rejects substantial truncation and a corrupt root reference" do
    [ valid_pdf_bytes.byteslice(0, 180), valid_pdf_bytes.sub("/Root 1 0 R", "/Root 9 0 R") ].each do |bytes|
      with_pdf(bytes) { |file| expect { described_class.validate!(file) }.to raise_error(described_class::InvalidPdf) }
    end
  end

  it "rejects a PDF that requires a password" do
    with_pdf(File.binread(Rails.root.join("spec/fixtures/files/password_required.pdf"))) do |file|
      expect { described_class.validate!(file) }.to raise_error(described_class::InvalidPdf)
    end
  end

  it "does not pretend every exit 2, including allocation and I/O failure, means bad input" do
    [ "qpdf: std::bad_alloc\n", "qpdf: open file: Permission denied\n", "unknown parser failure\n",
      "WARNING: suspicious content\nERROR: file does not contain any pages\nqpdf: std::bad_alloc\n" ].each do |output|
      status = double(exited?: true, exitstatus: 2)
      process = double(call: PdfCheckProcess::Result.new(status: status, output: output))
      with_pdf(valid_pdf_bytes) do |file|
        expect { described_class.new(process: process).validate!(file) }.to raise_error(described_class::Unavailable)
      end
    end
  end

  it "fails closed as unavailable when the parser cannot be started" do
    with_pdf(valid_pdf_bytes) do |file|
      expect { described_class.new(binary: "/missing/issue48-qpdf").validate!(file) }.to raise_error(described_class::Unavailable)
    end
  end

  it "does not reject missing EOF or renderer-tolerated content merely for conformance" do
    with_pdf(valid_pdf_bytes.sub("%%EOF\n", "")) { |file| expect(described_class.validate!(file)).to be(true) }
  end
end
