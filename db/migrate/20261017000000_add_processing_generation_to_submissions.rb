class AddProcessingGenerationToSubmissions < ActiveRecord::Migration[8.1]
  def change
    add_column :submissions, :processing_generation, :integer, default: 0, null: false
  end
end
