# Create synthetic identities ONLY in the isolated reproduction cluster.
require "json"
require "securerandom"
mode = ENV.fetch("QF_LOCAL_MODE")
raise "Wrong target" unless ENV["QF_LOCAL_ONLY"] == "1" && %w[dev check].include?(mode) && ENV["PGHOST"] == "db"
expected_env, expected_database = mode == "dev" ? [ "development", "quickflow_development" ] : [ "production", "quickflow_production" ]
raise "Wrong Rails mode" unless Rails.env == expected_env
raise "Wrong database" unless ActiveRecord::Base.connection.select_value("SELECT current_database()") == expected_database
raise "Fake AI missing" unless AiClient.build.is_a?(QfLocal::Client)
path = "/rails/tmp/local-http-fixture.private.json"
if File.exist?(path)
  existing = JSON.parse(File.read(path))
  raise "Wrong existing synthetic fixture" unless existing["mode"] == mode && existing["run"].start_with?("HTTPLOCAL") &&
    Teacher.exists?(user_id: existing["teacher_user"]) && Student.exists?(id: existing["student_id"])
  puts "Existing synthetic HTTP fixture is available in its private file."
  exit
end
run = "HTTPLOCAL" + SecureRandom.hex(5).upcase
password = "Synthetic-Only-#{SecureRandom.hex(16)}"
school = School.create!(school_code: run)
teacher = Teacher.create!(school: school, user_id: run.downcase, password: password)
classroom = Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1)
student = Student.create!(classroom: classroom, attendance_number: 1, password: password)
File.open("/rails/tmp/local-http-fixture.private.json", File::WRONLY | File::CREAT | File::EXCL, 0600) do |f|
  f.write(JSON.generate(mode: mode, run: run, teacher_user: teacher.user_id, password: password,
    school_code: school.school_code, classroom_id: classroom.id, student_id: student.id))
end
puts "Synthetic HTTP fixture prepared; credentials are in the private fixture file, not stdout."
