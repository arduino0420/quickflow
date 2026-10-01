class CreateSchools < ActiveRecord::Migration[8.1]
  def change
    create_table :schools, id: :bigint do |t|
      t.string :school_code, null: false

      t.timestamps
    end

    add_index :schools, :school_code, unique: true
  end
end
