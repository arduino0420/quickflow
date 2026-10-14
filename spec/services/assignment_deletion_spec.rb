require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe AssignmentDeletion do
  include_context "AI grading records"
  include ActiveJob::TestHelper

  before do
    assignment.assignment_classrooms.create!(classroom: classroom)
    submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nanswer"), filename: "answer.pdf", content_type: "application/pdf")
    @question = create_question
    @result = submission.grading_results.create!(question: @question, ai_judgment: :needs_review,
      teacher_judgment: :correct, ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    clear_enqueued_jobs
  end

  it "registers standard purge jobs only after deletion commits, and the jobs remove private files" do
    blobs = [ assignment.material_file.blob, submission.answer_file.blob ]
    blobs.each { |blob| expect(blob.service.exist?(blob.key)).to be(true) }
    expect { described_class.new.call(assignment, teacher: teacher) }.to have_enqueued_job(ActiveStorage::PurgeJob).exactly(2).times
    expect(ActiveStorage::Attachment.where(record: [ assignment, submission ])).to be_empty
    blobs.each { |blob| expect(blob.service.exist?(blob.key)).to be(true) }
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
    blobs.each do |blob|
      expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
      expect(blob.service.exist?(blob.key)).to be(false)
    end
  end

  it "preserves shared blobs and files attached to another assignment" do
    other = Assignment.create!(teacher: teacher, title: "共有", point_per_question: 5)
    blob = assignment.material_file.blob
    other.material_file.attach(blob)
    described_class.new.call(assignment, teacher: teacher)
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
    expect(other.reload.material_file.blob).to eq(blob)
    expect(blob.service.exist?(blob.key)).to be(true)
  end

  it "rolls back prior dependent deletions and does not enqueue file purges if a later deletion fails" do
    records = [ assignment, submission, @question, @result ]
    original = records.map { |record| record.reload.attributes }
    allow_any_instance_of(Question).to receive(:destroy!).and_raise(ActiveRecord::RecordNotDestroyed)
    expect { described_class.new.call(assignment, teacher: teacher) }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(records.map { |record| record.reload.attributes }).to eq(original)
    expect(enqueued_jobs.select { |job| job[:job] == ActiveStorage::PurgeJob }).to be_empty
    expect(submission.answer_file.download).to eq("%PDF-1.4\nanswer")
    expect(assignment.material_file).to be_attached
  end

  [ :incoming, :outgoing ].each do |kind|
    it "refuses #{kind} cross-assignment grading links instead of deleting another quiz's data" do
      other = Assignment.create!(teacher: teacher, title: "他", point_per_question: 5)
      other_question = create_question(owner: other)
      other_submission = Submission.create!(assignment: other, student: student, submitted_at: Time.current)
      cross = if kind == :incoming
        other_submission.grading_results.create!(question: @question, ai_judgment: :correct,
          ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
      else
        submission.grading_results.create!(question: other_question, ai_judgment: :correct,
          ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
      end
      original = cross.attributes
      expect { described_class.new.call(assignment, teacher: teacher) }.to raise_error(AssignmentDeletion::InconsistentData)
      expect(cross.reload.attributes).to eq(original)
      expect(assignment.reload).to be_persisted
      expect(submission.reload).to be_persisted
    end
  end

  it "reports committed DB deletion separately when purge job registration fails and logs recovery identifiers" do
    blob_ids = [ assignment.material_file.blob.id, submission.answer_file.blob.id ]
    allow(ActiveStorage::PurgeJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError, "queue unavailable")
    expect(Rails.logger).to receive(:error).with(a_string_including("Assignment PDF cleanup", "blobs", "service_name", "key"))
    expect(described_class.new.call(assignment, teacher: teacher)).to eq(:cleanup_pending)
    expect(Assignment.exists?(assignment.id)).to be(false)
    expect(Submission.exists?(submission.id)).to be(false)
    expect(ActiveStorage::Blob.where(id: blob_ids).count).to eq(2)
    # Queue recovery re-registers only still-unattached blobs; standard Rails purge is used.
    allow(ActiveStorage::PurgeJob).to receive(:perform_later).and_call_original
    ActiveStorage::Blob.where(id: blob_ids).each { |blob| blob.purge_later unless blob.attachments.exists? }
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
    expect(ActiveStorage::Blob.where(id: blob_ids)).to be_empty
  end

  it "rechecks the creator under the row lock instead of trusting a stale owner" do
    other = Teacher.create!(school: school, user_id: "new-owner", password: "password123")
    Assignment.where(id: assignment.id).update_all(teacher_id: other.id)
    expect { described_class.new.call(assignment, teacher: teacher) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(assignment.reload.teacher_id).to eq(other.id)
    expect(submission.reload).to be_persisted
  end

  it "detects a false return from standard purge registration without reporting physical deletion success" do
    blob_ids = [ assignment.material_file.blob.id, submission.answer_file.blob.id ]
    allow(ActiveStorage::PurgeJob).to receive(:perform_later).and_return(false)
    expect(Rails.logger).to receive(:error).with(a_string_including("PurgeJobNotEnqueued"))
    expect(described_class.new.call(assignment, teacher: teacher)).to eq(:cleanup_pending)
    expect(Assignment.exists?(assignment.id)).to be(false)
    expect(ActiveStorage::Blob.where(id: blob_ids).count).to eq(2)
  end
end
