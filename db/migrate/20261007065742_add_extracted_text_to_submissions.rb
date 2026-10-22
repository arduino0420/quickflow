class AddExtractedTextToSubmissions < ActiveRecord::Migration[8.1]
  def change
    add_column :submissions, :extracted_text, :text
  end
end
