class ClassroomGradeExporter
  def call(assignment, classroom)
    students = classroom.students.index_by(&:attendance_number)
    submissions = assignment.reviewable_submissions.where(student: students.values)
      .includes(:assignment).index_by(&:student_id)
    classroom_name = "#{classroom.grade}年#{classroom.class_number}組"

    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: classroom_name) do |sheet|
      sheet.add_row [ "クラス", "出席番号", "得点" ]
      (1..40).each do |number|
        student = students[number]
        score = submissions[student&.id]&.score
        sheet.add_row [ classroom_name, number, score ], types: [ :string, :integer, :integer ]
      end
    end
    package.to_stream.string
  end
end
