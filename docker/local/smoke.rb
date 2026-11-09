# Run with bin/rails runner /local/smoke.rb INSIDE the isolated web container.
require "json"
require "rack/test"
require "action_dispatch/testing/integration"
require "nokogiri"
require "zip"
require "securerandom"
mode = ENV.fetch("QF_LOCAL_MODE")
raise "Wrong environment" unless ENV["QF_LOCAL_ONLY"] == "1" && %w[dev check].include?(mode) && ENV["PGHOST"] == "db"
expected_env, expected_database = mode == "dev" ? [ "development", "quickflow_development" ] : [ "production", "quickflow_production" ]
raise "Wrong Rails mode" unless Rails.env == expected_env
raise "Fake AI missing" unless AiClient.build.is_a?(QfLocal::Client)
expected_adapter = mode == "dev" ? ActiveJob::QueueAdapters::AsyncAdapter : ActiveJob::QueueAdapters::SolidQueueAdapter
raise "Wrong job adapter" unless ActiveJob::Base.queue_adapter.is_a?(expected_adapter)
raise "Wrong database" unless ActiveRecord::Base.connection.select_value("SELECT current_database()") == expected_database
raise "Wrong primary host" unless ActiveRecord::Base.connection_db_config.configuration_hash[:host].to_s.in?([ "", "db" ])
# The caller MUST additionally verify the Docker project, internal network and new volume identities before running.

module QfSmoke
  def self.check(name, ok)
    raise "FAIL: #{name}" unless ok
    puts JSON.generate(check: name, passed: true)
    STDOUT.flush
  end
  def self.wait(name, timeout: 120)
    stop = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "TIMEOUT: #{name}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= stop
      sleep 0.5
    end
    check(name, true)
  end
  def self.session
    s = ActionDispatch::Integration::Session.new(Rails.application)
    s.host! "localhost"
    s.https! if ENV["QF_LOCAL_MODE"] == "check"
    s
  end
  def self.token(s)
    token = Nokogiri::HTML(s.response.body).at_css('meta[name="csrf-token"]')&.[]("content")
    raise "CSRF token unavailable" unless token.present?
    token
  end
  def self.pdf
    stream = "BT /F1 18 Tf 40 700 Td (SYNTHETIC TEST ONLY: 1+1=2) Tj ET\n"
    objects = [ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
      "<< /Length #{stream.bytesize} >>\nstream\n#{stream}endstream", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>" ]
    bytes = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map { |o, i| pos=bytes.bytesize; bytes << "#{i+1} 0 obj\n#{o}\nendobj\n"; pos }
    xref=bytes.bytesize
    bytes << "xref\n0 6\n0000000000 65535 f \n"
    offsets.each { |o| bytes << format("%010d 00000 n \n", o) }
    bytes << "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    bytes
  end
  def self.upload(path) = Rack::Test::UploadedFile.new(path, "application/pdf", original_filename: "synthetic.pdf")
end

run = "LOCAL" + SecureRandom.hex(5).upcase
password = "Synthetic-Only-#{SecureRandom.hex(10)}"
school = School.create!(school_code: run)
teacher = Teacher.create!(school: school, user_id: run.downcase, password: password)
classroom = Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1)
student = Student.create!(classroom: classroom, attendance_number: 1, password: password)
path = "/rails/tmp/#{run}.pdf"
File.binwrite(path, QfSmoke.pdf)

teacher_http = QfSmoke.session
teacher_http.get "/login"
QfSmoke.check("teacher_login_page", teacher_http.response.status == 200)
teacher_http.post "/login", params: { authenticity_token: QfSmoke.token(teacher_http), session: { user_id: teacher.user_id, password: password } }
QfSmoke.check("teacher_login_with_csrf", teacher_http.response.status == 303 && teacher_http.response.location.end_with?("/assignments"))
teacher_http.get "/assignments/new"
teacher_http.post "/assignments", params: { authenticity_token: QfSmoke.token(teacher_http), assignment: { title: "Synthetic #{run}", point_per_question: 5, classroom_ids: [ classroom.id.to_s ], material_file: QfSmoke.upload(path) } }
QfSmoke.check("teacher_pdf_distribution", teacher_http.response.status == 303)
assignment = teacher.assignments.find_by!(title: "Synthetic #{run}")
QfSmoke.check("material_bytes_preserved", assignment.material_file.download == File.binread(path))
QfSmoke.wait("configured_worker_question_generation") { assignment.questions.count == 1 && assignment.reload.current_question_generation_request.state == "succeeded" }
QfSmoke.check("fake_question_model", assignment.questions.first.answer_generation_model == QfLocal::MODEL)

student_http = QfSmoke.session
student_http.get "/student/login"
student_http.post "/student/login", params: { authenticity_token: QfSmoke.token(student_http), student_session: { school_code: school.school_code, grade: "1", class_number: "1", attendance_number: "1", password: password } }
QfSmoke.check("student_login_with_csrf", student_http.response.status == 303 && student_http.response.location.end_with?("/student/assignments"))
student_http.get "/student/assignments/#{assignment.id}"
QfSmoke.check("student_assignment_visible", student_http.response.status == 200)
submission_path = "/student/assignments/#{assignment.id}/submission"
student_http.post submission_path, params: { authenticity_token: QfSmoke.token(student_http), submission: { answer_file: QfSmoke.upload(path) } }
QfSmoke.check("student_pdf_submission", student_http.response.status == 303)
submission = student.submissions.find_by!(assignment: assignment)
QfSmoke.check("answer_bytes_preserved", submission.answer_file.download == File.binread(path))
student_http.get "/student/assignments/#{assignment.id}"
student_http.post submission_path, params: { authenticity_token: QfSmoke.token(student_http), submission: { answer_file: QfSmoke.upload(path) } }
QfSmoke.check("repeat_submission_one_row", student_http.response.status == 303 && student.submissions.where(assignment: assignment).count == 1)
QfSmoke.wait("configured_worker_reading_and_grading") { submission.reload.completed? }
result = submission.grading_results.sole
QfSmoke.check("synthetic_ai_result_saved", result.ai_judgment == "correct" && result.ai_model_name == QfLocal::MODEL && submission.score == 5)
student_http.get "/student/assignments/#{assignment.id}"
QfSmoke.check("student_result_visible", student_http.response.status == 200 && student_http.response.body.include?("5点"))

teacher_http.get "/assignments/#{assignment.id}/submissions/#{submission.id}"
QfSmoke.check("teacher_review_visible", teacher_http.response.status == 200)
teacher_http.patch "/assignments/#{assignment.id}/submissions/#{submission.id}", params: { authenticity_token: QfSmoke.token(teacher_http), final_judgments: { result.id.to_s => "incorrect" }, original_final_judgments: { result.id.to_s => "correct" } }
QfSmoke.check("teacher_override_without_overwriting_ai", teacher_http.response.status == 303 && result.reload.teacher_judgment == "incorrect" && result.ai_judgment == "correct" && submission.reload.score == 0)
teacher_http.get "/assignments/#{assignment.id}/export.xlsx", params: { classroom_id: classroom.id.to_s }
QfSmoke.check("xlsx_download", teacher_http.response.status == 200 && teacher_http.response.media_type == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
xml=nil
Zip::File.open_buffer(StringIO.new(teacher_http.response.body)) { |z| xml=z.read("xl/worksheets/sheet1.xml") }
sheet=Nokogiri::XML(xml).remove_namespaces!
QfSmoke.check("xlsx_corrected_score", sheet.at_xpath("/worksheet/sheetData/row/c[@r='C2']/v")&.text == "0")
student_http.get "/student/assignments/#{assignment.id}"
QfSmoke.check("student_corrected_result", student_http.response.status == 200 && student_http.response.body.include?("0点"))
puts JSON.generate(outcome: "PASS", synthetic_school: run, assignment_id: assignment.id, submission_id: submission.id,
  scope: "Rails configured-mode request integration + actual configured worker + synthetic AI boundary; no real external AI, no browser canvas test")
