class AssignmentDeletion
  class InconsistentData < StandardError; end

  def call(assignment, teacher:)
    raise ActiveRecord::RecordNotFound unless assignment.teacher_id == teacher.id

    manifests = []
    deleted_here = false
    queued_blob_ids = []
    calling_thread = Thread.current
    observer = lambda do |event|
      job = event.payload[:job]
      if Thread.current == calling_thread && job.is_a?(ActiveStorage::PurgeJob) && job.successfully_enqueued?
        queued_blob_ids << job.arguments.first.id
      end
    end
    ActiveSupport::Notifications.subscribed(observer, "enqueue.active_job") do
      AssignmentLifecycleLock.synchronize(assignment.id) do
        begin
          # KEY SHARE acquired by existing jobs' FK checks must remain compatible
          # while waiting for their submission locks. DELETE upgrades only at the end.
          assignment.with_lock("FOR NO KEY UPDATE", requires_new: true) do
            raise ActiveRecord::RecordNotFound unless assignment.teacher_id == teacher.id

            submissions = assignment.submissions.order(:id).lock.to_a
            questions = assignment.questions.order(:id).lock.to_a
            validate_scope!(assignment, teacher, submissions, questions)
            manifests = attachments_for(assignment, submissions).map(&:blob).uniq(&:id).map do |blob|
              { id: blob.id, service_name: blob.service_name, key: blob.key }
            end
            submission_ids = submissions.map(&:id)
            question_ids = questions.map(&:id)
            GradingResult.where(submission_id: submission_ids).order(:id).each(&:destroy!)
            submissions.each(&:destroy!)
            questions.each(&:destroy!)
            assignment.assignment_classrooms.order(:id).each(&:destroy!)
            assignment.destroy!
            deleted_here = true
          end
        rescue StandardError => error
          raise unless deleted_here && !Assignment.exists?(assignment.id)

          # after_destroy_commit can fail to register a purge job after the DB commit.
          log_cleanup(assignment.id, manifests, level: :error, error: error.class.name)
          return :cleanup_pending
        end
        pending = manifests.any? do |item|
          !queued_blob_ids.include?(item[:id]) && ActiveStorage::Blob.exists?(item[:id]) &&
            !ActiveStorage::Attachment.exists?(blob_id: item[:id])
        end
        log_cleanup(assignment.id, manifests, level: pending ? :error : :info,
          error: ("PurgeJobNotEnqueued" if pending))
        pending ? :cleanup_pending : :deleted
      end
    end
  end

  private

  def validate_scope!(assignment, teacher, submissions, questions)
    foreign_class = assignment.classrooms.where.not(school_id: teacher.school_id).exists?
    foreign_student = Student.joins(:classroom).where(id: submissions.map(&:student_id))
      .where.not(classrooms: { school_id: teacher.school_id }).exists?
    submission_ids = submissions.map(&:id)
    question_ids = questions.map(&:id)
    outgoing = GradingResult.where(submission_id: submission_ids).where.not(question_id: question_ids).exists?
    incoming = GradingResult.where(question_id: question_ids).where.not(submission_id: submission_ids).exists?
    raise InconsistentData if foreign_class || foreign_student || outgoing || incoming
  end

  def attachments_for(assignment, submissions)
    [ assignment.material_file_attachment, *submissions.map(&:answer_file_attachment) ].compact
  end

  def log_cleanup(assignment_id, manifests, level: :info, error: nil)
    # Opaque storage identifiers allow recovery if standard purge deleted the Blob row
    # before a storage failure. No titles, student information, answers or API keys.
    unshared = manifests.reject { |item| ActiveStorage::Attachment.exists?(blob_id: item[:id]) }
    Rails.logger.public_send(level, "Assignment PDF cleanup: #{JSON.generate(assignment_id: assignment_id, blobs: unshared, error: error)}")
  end
end
