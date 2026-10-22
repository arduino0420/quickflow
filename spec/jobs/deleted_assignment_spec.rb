require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "AI jobs after assignment deletion", type: :job do
  include_context "AI grading records"

  [ QuestionGenerationJob, AnswerReadingJob, AnswerGradingJob ].each do |job_class|
    [ :serialized, :already_loaded ].each do |mode|
      it "safely finishes #{job_class} with #{mode} arguments after deletion without AI or recreated data" do
        submission
        args = job_class == QuestionGenerationJob ? [ assignment, assignment.material_file.blob.id ] : [ submission ]
        serialized = job_class.new(*args).serialize
        AssignmentDeletion.new.call(assignment, teacher: teacher)
        expect(AiClient).not_to receive(:build)
        expect_any_instance_of(QuestionGenerator).not_to receive(:record_failure)
        expect {
          mode == :serialized ? ActiveJob::Base.execute(serialized) : job_class.perform_now(*args)
        }.not_to raise_error
        expect(Assignment.exists?(assignment.id)).to be(false)
        expect(Submission.where(assignment_id: assignment.id)).to be_empty
        expect(Question.where(assignment_id: assignment.id)).to be_empty
      end
    end
  end

  it "does not swallow unrelated deserialization failures" do
    serialized = QuestionGenerationJob.new(assignment, assignment.material_file.blob.id).serialize
    serialized["arguments"][0]["_aj_globalid"] = "gid://quickflow/NotAnExistingJobModel/1"
    expect(AiClient).not_to receive(:build)
    expect { ActiveJob::Base.execute(serialized) }.to raise_error(ActiveJob::DeserializationError)
    expect(assignment.reload).to be_persisted
  end

  it "does not discard unrelated missing records when the primary job target still exists" do
    assignment
    allow(assignment).to receive(:reload).and_raise(ActiveRecord::RecordNotFound, "unrelated lookup")
    expect(AiClient).not_to receive(:build)
    expect { QuestionGenerationJob.perform_now(assignment, assignment.material_file.blob.id) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(Assignment.exists?(assignment.id)).to be(true)
  end
end
