class AssignmentsController < ApplicationController
  before_action :require_teacher_login
  before_action :set_classrooms, only: [ :new, :create ]
  before_action :set_assignment, only: [ :edit, :update ]
  before_action :set_assignment_and_classroom, only: [ :show, :export ]

  def index
    @assignments = distributed_assignments.order(created_at: :desc, id: :desc)
  end

  def show
    @reviewable_submissions = @assignment.reviewable_submissions.where(students: { classroom_id: @selected_classrooms.select(:id) })
    results = @assignment.reviewable_grading_results.where(submission: @reviewable_submissions)
    @pending_review_counts = results.pending_review.group(:submission_id).count
    @pending_review_count = @pending_review_counts.values.sum
    set_submission_summary
    @review_only = params[:filter] == "needs_review"
    if @review_only
      student_ids = @submissions_by_student_id.values.select { |submission| @pending_review_counts.fetch(submission.id, 0).positive? }.map(&:student_id)
      @students = @students.where(id: student_ids)
    end
  end

  def export
    raise ActiveRecord::RecordNotFound unless params.key?(:classroom_id)

    data = ClassroomGradeExporter.new.call(@assignment, @selected_classrooms.to_a)
    classroom_name = @selected_classroom ? helpers.classroom_label(@selected_classroom) : "全クラス"
    filename = ActiveStorage::Filename.new(
      "課題#{@assignment.id}_#{@assignment.title}_#{classroom_name}_成績.xlsx"
    ).sanitized
    response.headers["Cache-Control"] = "private, no-store"
    send_data data, filename: filename,
      type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", disposition: :attachment
  end

  def new
    @assignment = current_teacher.assignments.build
    @selected_classroom_ids = []
  end

  def edit
  end

  def update
    if @assignment.update(params.require(:assignment).permit(:title))
      redirect_to assignment_path(@assignment), notice: "小テスト名を変更しました。", status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def create
    @assignment = current_teacher.assignments.build(assignment_params)

    @selected_classroom_ids = []
    @assignment.valid?
    @assignment.errors.add(:material_file, "を選択してください") unless @assignment.material_file.attached?
    selected_classrooms = selected_classrooms_for_creation

    return render_creation_errors if @assignment.errors.any?

    Assignment.transaction do
      @assignment.save!
      selected_classrooms.each do |classroom|
        @assignment.assignment_classrooms.create!(classroom: classroom)
      end
    end

    enqueue_question_generation
    redirect_to new_assignment_path, notice: "小テストを配信しました", status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    @assignment.errors.add(:base, "配信先を保存できませんでした") unless error.record.equal?(@assignment)
    render_creation_errors
  end

  private

  def set_assignment
    @assignment = distributed_assignments.find(params[:id])
  end

  def set_assignment_and_classroom
    set_assignment
    @classrooms = @assignment.classrooms.where(school_id: current_teacher.school_id).order(:grade, :class_number)
    set_selected_classroom
  end

  def set_selected_classroom
    id = params[:classroom_id]
    if !params.key?(:classroom_id) || id == "all"
      @selected_classrooms = @classrooms
      @classroom_selection = "all"
      return
    end

    raise ActiveRecord::RecordNotFound unless id.is_a?(String) && id.match?(/\A[1-9][0-9]*\z/)

    @selected_classroom = @classrooms.find(id)
    @selected_classrooms = @classrooms.where(id: @selected_classroom.id)
    @classroom_selection = @selected_classroom.id
  end

  def set_submission_summary
    @students = Student.where(classroom: @selected_classrooms).joins(:classroom).includes(:classroom)
      .order("classrooms.grade", "classrooms.class_number", "students.attendance_number")
    @submissions_by_student_id = @reviewable_submissions.includes(:assignment).index_by(&:student_id)
    @scores_by_submission_id = @submissions_by_student_id.values.select(&:completed?).to_h do |submission|
      [ submission.id, submission.score ]
    end
  end

  def enqueue_question_generation
    job = QuestionGenerationJob.perform_later(@assignment, @assignment.material_file.blob.id)
    raise "Could not enqueue question generation" unless job
  rescue StandardError => error
    QuestionGenerator.new.record_failure(@assignment)
    Rails.logger.error("Question generation enqueue failed: #{error.class}: #{error.message}")
  end

  def distributed_assignments
    current_teacher.assignments.distributed_to_school(current_teacher.school_id)
  end

  def require_teacher_login
    redirect_to login_path, status: :see_other unless current_teacher
  end

  def set_classrooms
    @classrooms = Classroom.where(school_id: current_teacher.school_id).order(:grade, :class_number)
  end

  def selected_classrooms_for_creation
    ids = params[:assignment][:classroom_ids]
    unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(String) && (id.empty? || id.match?(/\A[1-9][0-9]*\z/)) }
      @assignment.errors.add(:base, "配信先クラスを正しく選択してください")
      return []
    end

    permitted_ids = params.require(:assignment).permit(classroom_ids: [])[:classroom_ids]
    requested_ids = permitted_ids.reject(&:empty?).map(&:to_i).uniq
    classrooms = @classrooms.where(id: requested_ids).to_a
    @selected_classroom_ids = classrooms.map(&:id)

    if requested_ids.empty?
      @assignment.errors.add(:base, "最低1クラスを選択してください")
    elsif @selected_classroom_ids.sort != requested_ids.sort
      @assignment.errors.add(:base, "配信先クラスを正しく選択してください")
    end
    classrooms
  end

  def render_creation_errors
    failed_assignment = @assignment
    @assignment = current_teacher.assignments.build(
      title: failed_assignment.title,
      point_per_question: failed_assignment.point_per_question_before_type_cast
    )
    @assignment.errors.copy!(failed_assignment.errors)
    render :new, status: :unprocessable_entity
  end

  def assignment_params
    params.require(:assignment).permit(:title, :point_per_question, :material_file)
  end
end
