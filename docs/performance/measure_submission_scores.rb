require 'json'
raise 'wrong database' unless Rails.env.test? && ActiveRecord::Base.connection.select_value('SELECT inet_server_port()') == Integer(ENV.fetch('QUICKFLOW_BENCHMARK_PORT'))
OpenAI::Client.define_singleton_method(:new) { |*| raise 'AI disabled' }
ActiveRecord::Base.transaction do
  school = School.create!(school_code: "PERF49#{SecureRandom.hex(3)}")
  teacher = Teacher.create!(school: school, user_id: "perf49#{SecureRandom.hex(3)}", password: 'password123')
  classroom = Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1)
  students = (1..40).map { |n| Student.create!(classroom: classroom, attendance_number: n, password: 'password123') }
  assignments = 3.times.map do |n|
    a = Assignment.create!(teacher: teacher, title: "Synthetic #{n}", point_per_question: 5)
    a.assignment_classrooms.create!(classroom: classroom)
    questions = 10.times.map { |i| a.questions.create!(question_label: (i+1).to_s, position: i+1, question_text: '1+1', correct_answer: '2', grading_rule: '{}', answer_generation_model: 'synthetic', answer_generation_prompt_version: 'v1', answer_generated_at: Time.current) }
    students.each do |student|
      sub = Submission.create!(assignment: a, student: student, status: :completed, submitted_at: Time.current)
      questions.each_with_index { |q, i| sub.grading_results.create!(question: q, ai_judgment: i.even? ? :correct : :needs_review, ai_model_name: 'synthetic', prompt_version: 'v1', graded_at: Time.current) }
    end
    a
  end
  # Give the isolated synthetic tables representative planner statistics.
  %w[schools teachers classrooms students assignments assignment_classrooms questions submissions grading_results].each do |table|
    ActiveRecord::Base.connection.execute("ANALYZE #{table}")
  end
  session = ActionDispatch::Integration::Session.new(Rails.application)
  session.post('/login', params: { session: { user_id: teacher.user_id, password: 'password123' } })
  raise "login #{session.response.status}" unless session.response.status == 303
  routes = { teacher_list: '/assignments', teacher_grades: "/assignments/#{assignments.first.id}?classroom_id=#{classroom.id}", teacher_filtered: "/assignments/#{assignments.first.id}?classroom_id=#{classroom.id}&filter=needs_review", export: "/assignments/#{assignments.first.id}/export?classroom_id=#{classroom.id}" }
  report = { head: `git rev-parse HEAD`.strip, measurements: {} }
  measure = lambda do |name, path|
    2.times { session.get(path); raise "#{name}: #{session.response.status}" unless session.response.status == 200 }
    runs = 9.times.map do
      events = []
      subscriber = ->(*args) { p = args.last; events << p.slice(:sql, :cached) if p[:sql].match?(/\ASELECT/i) && p[:name] != 'SCHEMA' }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { session.get(path) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      raise "#{name}: #{session.response.status}" unless session.response.status == 200
      groups = events.group_by { |e| e[:sql].match(/\bFROM "([^"]+)"/)&.captures&.first || "other" }.transform_values { |v| { physical: v.count { |e| !e[:cached] }, cached: v.count { |e| e[:cached] } } }
      { ms: (elapsed*1000).round(3), physical: events.count { |e| !e[:cached] }, cached: events.count { |e| e[:cached] }, groups: groups }
    end
    report[:measurements][name] = runs
  end
  routes.each { |name, path| measure.call(name, path) }
  session.post('/student/login', params: { student_session: { school_code: school.school_code, grade: 1, class_number: 1, attendance_number: 1, password: 'password123' } })
  raise "student login #{session.response.status}" unless session.response.status == 303
  measure.call(:student_list, '/student/assignments')
  puts JSON.pretty_generate(report)
  raise ActiveRecord::Rollback
end
