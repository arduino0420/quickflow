require "zip"

module XlsxInspection
  def xlsx_worksheet(data)
    xml = nil
    Zip::File.open_buffer(StringIO.new(data)) do |archive|
      xml = archive.read("xl/worksheets/sheet1.xml")
    end
    Nokogiri::XML(xml).remove_namespaces!
  end

  def xlsx_cell(sheet, reference)
    sheet.at_xpath("/worksheet/sheetData/row/c[@r='#{reference}']")
  end

  def xlsx_value(sheet, reference)
    cell = xlsx_cell(sheet, reference)
    return unless cell

    if cell["t"] == "inlineStr"
      cell.xpath("./is//t").map(&:text).join
    else
      cell.at_xpath("./v")&.text
    end
  end
end
