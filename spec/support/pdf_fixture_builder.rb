module PdfFixtureBuilder
  def valid_pdf_bytes(size: nil, content: "q Q\n", content_reference: 4)
    padding = 0
    loop do
      stream = size ? "%#{'x' * padding}\n" : content
      objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> /Contents #{content_reference} 0 R >>",
        "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"
      ]
      bytes = +"%PDF-1.4\n"
      offsets = objects.each_with_index.map do |object, index|
        offset = bytes.bytesize
        bytes << "#{index + 1} 0 obj\n#{object}\nendobj\n"
        offset
      end
      xref = bytes.bytesize
      bytes << "xref\n0 5\n0000000000 65535 f \n"
      offsets.each { |offset| bytes << format("%010d 00000 n \n", offset) }
      bytes << "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
      return bytes unless size && bytes.bytesize != size

      padding += size - bytes.bytesize
      raise ArgumentError, "size too small" if padding.negative?
    end
  end
end
