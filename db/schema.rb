# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_02_070915) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "assignment_classrooms", force: :cascade do |t|
    t.bigint "assignment_id", null: false
    t.bigint "classroom_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["assignment_id", "classroom_id"], name: "index_assignment_classrooms_on_assignment_id_and_classroom_id", unique: true
    t.index ["assignment_id"], name: "index_assignment_classrooms_on_assignment_id"
    t.index ["classroom_id"], name: "index_assignment_classrooms_on_classroom_id"
  end

  create_table "assignments", force: :cascade do |t|
    t.bigint "teacher_id", null: false
    t.string "title", null: false
    t.integer "point_per_question", null: false
    t.datetime "published_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["teacher_id"], name: "index_assignments_on_teacher_id"
  end

  create_table "classrooms", force: :cascade do |t|
    t.bigint "school_id", null: false
    t.bigint "teacher_id", null: false
    t.integer "grade", null: false
    t.integer "class_number", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["school_id", "grade", "class_number"], name: "index_classrooms_on_school_id_and_grade_and_class_number", unique: true
    t.index ["school_id"], name: "index_classrooms_on_school_id"
    t.index ["teacher_id"], name: "index_classrooms_on_teacher_id"
  end

  create_table "schools", force: :cascade do |t|
    t.string "school_code", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["school_code"], name: "index_schools_on_school_code", unique: true
  end

  create_table "students", force: :cascade do |t|
    t.bigint "classroom_id", null: false
    t.integer "attendance_number", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["classroom_id", "attendance_number"], name: "index_students_on_classroom_id_and_attendance_number", unique: true
    t.index ["classroom_id"], name: "index_students_on_classroom_id"
  end

  create_table "teachers", force: :cascade do |t|
    t.bigint "school_id", null: false
    t.string "user_id", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["school_id"], name: "index_teachers_on_school_id"
    t.index ["user_id"], name: "index_teachers_on_user_id", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "assignment_classrooms", "assignments"
  add_foreign_key "assignment_classrooms", "classrooms"
  add_foreign_key "assignments", "teachers"
  add_foreign_key "classrooms", "schools"
  add_foreign_key "classrooms", "teachers"
  add_foreign_key "students", "classrooms"
  add_foreign_key "teachers", "schools"
end
