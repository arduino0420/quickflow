class RenameModelNameInGradingResults < ActiveRecord::Migration[8.1]
  def change
    rename_column :grading_results, :model_name, :ai_model_name
  end
end
