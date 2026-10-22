class ClassroomGradeExporter
  def call(assignment, classroom)
    classrooms = Array.wrap(classroom).sort_by { |item| [ item.grade, item.class_number ] }
    students = Student.where(classroom: classrooms).index_by { |student| [ student.classroom_id, student.attendance_number ] }
    submissions = assignment.reviewable_submissions.where(student: students.values)
      .includes(:assignment).index_by(&:student_id)
    scores = SubmissionScores.new.call(submissions.values)
    sheet_name = classrooms.one? ? "#{classrooms.first.grade}年#{classrooms.first.class_number}組" : "全クラス"

    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: sheet_name) do |sheet|
      sheet.add_row [ "クラス", "出席番号", "得点" ]
      classrooms.each do |target|
        classroom_name = "#{target.grade}年#{target.class_number}組"
        (1..40).each do |number|
          student = students[[ target.id, number ]]
          score = scores[submissions[student&.id]&.id]
          sheet.add_row [ classroom_name, number, score ], types: [ :string, :integer, :integer ]
        end
      end
    end
    package.to_stream.string
  end
end
