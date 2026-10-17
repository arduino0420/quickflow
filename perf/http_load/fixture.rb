require "json"
require "securerandom"

run_id = ENV.fetch("QUICKFLOW_HTTP_LOAD_RUN_ID")
raise "unsafe run id" unless run_id.match?(/\A[a-z0-9]+\z/)
raise "wrong database" unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database == "quickflow_test"

school_code = "LOAD#{run_id[-12, 12]}".upcase
password = SecureRandom.hex(16)
school = School.create!(school_code: school_code)
teacher = Teacher.create!(school: school, user_id: "load_#{run_id}", password: password)
classroom = Classroom.create!(school: school, grade: 1, class_number: 1)
students = (1..31).map { |number| Student.create!(classroom: classroom, attendance_number: number, password: password) }
assignments = %w[canary ordinary handwritten].to_h do |mode|
  assignment = Assignment.create!(teacher: teacher, title: "HTTP load #{run_id} #{mode}", point_per_question: 5)
  assignment.assignment_classrooms.create!(classroom: classroom)
  assignment.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/material.pdf")),
    filename: "material.pdf", content_type: "application/pdf")
  [ mode, assignment.id ]
end

path = Rails.root.join("tmp", "http_load_fixture_#{run_id}.json")
File.write(path, JSON.generate({ school_code: school_code, password: password, assignments: assignments,
  student_ids: students.map(&:id), run_id: run_id }))
File.chmod(0o600, path)
puts JSON.generate({ run_id: run_id, database: ActiveRecord::Base.connection_db_config.database,
  db_host: ActiveRecord::Base.connection_db_config.host, storage_root: ActiveStorage::Blob.service.root.to_s,
  csrf: ActionController::Base.allow_forgery_protection,
  adapter: ActiveJob::Base.queue_adapter.class.name,
  job_execution_guard: ActiveJob::Base.ancestors.any? { |ancestor| ancestor.instance_methods(false).include?(:perform_now) && ancestor.name.nil? } })
