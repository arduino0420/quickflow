
require "rails_helper"

RSpec.describe AnswerReadingJob, type: :job do
  include ActiveJob::TestHelper
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "student-password") }
  let(:assignment) { Assignment.create!(teacher: teacher, title: "式の計算", point_per_question: 5) }

  let(:submission) do
    Submission.create!(
      student: student,
      assignment: assignment,
      status: :submitted,
      submitted_at: Time.current
    )
  end

  let(:valid_result) do
    {
      problems: [
        {
          question_label: "1(1)",
          question_text: "3x + 2x を計算しなさい。",
          student_answer: "5x",
          reading_status: "readable",
          reading_reason: "最終解答を明確に読み取れる"
        }
      ]
    }.to_json
  end

  it "saves valid JSON reading results to the submission" do
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    allow(reader).to receive(:call).with(submission).and_return(valid_result)

    described_class.perform_now(submission)

    data = JSON.parse(submission.reload.extracted_text)

    expect(data["problems"].first["question_label"]).to eq("1(1)")
    expect(data["problems"].first["question_text"]).to eq("3x + 2x を計算しなさい。")
    expect(data["problems"].first["student_answer"]).to eq("5x")
    expect(data["problems"].first["reading_status"]).to eq("readable")
    expect(submission).to be_grading
  end

  it "marks the submission as failed when JSON is invalid" do
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    allow(reader).to receive(:call).with(submission).and_return("invalid JSON")

    described_class.perform_now(submission)

    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to be_nil
  end

  it "marks the submission as failed when the AI raises an error" do
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    allow(reader).to receive(:call).with(submission).and_raise(StandardError, "API error")

    described_class.perform_now(submission)

    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to be_nil
  end

  it "logs a reading timeout without retrying or enqueuing grading" do
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    error = OpenAI::Errors::APITimeoutError.new(url: URI("https://example.invalid"), message: "Timed out")
    allow(reader).to receive(:call).and_raise(error)
    allow(Rails.logger).to receive(:error)

    expect do
      described_class.perform_now(submission)
      described_class.perform_now(Submission.find(submission.id))
    end.not_to have_enqueued_job(AnswerGradingJob)
    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to be_nil
    expect(reader).to have_received(:call).once
    expect(Rails.logger).to have_received(:error).with(/AnswerReadingJob failed: .*APITimeoutError: Timed out/).once
  end

  it "marks the submission as failed when required fields are missing" do
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    allow(reader).to receive(:call).with(submission).and_return(
      { problems: [ { question_label: "1(1)" } ] }.to_json
    )

    described_class.perform_now(submission)

    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to be_nil
  end

  it "enqueues grading only after saving the reading result" do
    reader = instance_double(AnswerReader, call: valid_result)
    allow(AnswerReader).to receive(:new).and_return(reader)
    expect { described_class.perform_now(submission) }.to have_enqueued_job(AnswerGradingJob).with(submission)
    expect(submission.reload.extracted_text).to be_present
    expect(submission).to be_grading
    expect(enqueued_jobs.count { |job| job[:job] == AnswerGradingJob }).to eq(1)
  end

  it "reuses saved readings without another reading API call" do
    submission.update!(status: :grading, extracted_text: valid_result)
    expect(AnswerReader).not_to receive(:new)
    expect { described_class.perform_now(submission) }.to have_enqueued_job(AnswerGradingJob).with(submission)
    expect(submission.reload.extracted_text).to eq(valid_result)
  end

  it "does not start grading after a reading error" do
    allow(AnswerReader).to receive(:new).and_raise(StandardError, "Reading failed")
    expect { described_class.perform_now(submission) }.not_to have_enqueued_job(AnswerGradingJob)
  end

  [ :completed, :failed ].each do |status|
    it "skips a #{status} submission without calling or enqueuing AI work" do
      submission.update!(status: status)
      expect(AnswerReader).not_to receive(:new)
      expect { described_class.perform_now(submission) }.not_to have_enqueued_job(AnswerGradingJob)
      expect(submission.reload.status).to eq(status.to_s)
    end
  end

  [ :rejected, :exception ].each do |failure|
    it "preserves saved readings and stops repeat registration after #{failure}" do
      submission.update!(extracted_text: valid_result)
      expect(AnswerReader).not_to receive(:new)
      if failure == :rejected
        allow(AnswerGradingJob).to receive(:perform_later).and_return(false)
      else
        allow(AnswerGradingJob).to receive(:perform_later).and_raise(StandardError, "PRIVATE QUEUE ERROR")
      end
      allow(Rails.logger).to receive(:error)
      described_class.perform_now(submission)
      described_class.perform_now(Submission.find(submission.id))
      expect(submission.reload).to be_failed
      expect(submission.extracted_text).to eq(valid_result)
      expect(submission.grading_results).to be_empty
      expect(AnswerGradingJob).to have_received(:perform_later).with(submission).once
      expect(Rails.logger).to have_received(:error).with(/AnswerReadingJob grading enqueue failed: submission_id=#{submission.id} (RuntimeError|StandardError)\z/).once
      expect(Rails.logger).not_to have_received(:error).with(/PRIVATE/)
    end
  end

  it "retains newly read data when grading registration is rejected" do
    reader = instance_double(AnswerReader, call: valid_result)
    allow(AnswerReader).to receive(:new).and_return(reader)
    allow(AnswerGradingJob).to receive(:perform_later).and_return(false)
    described_class.perform_now(submission)
    described_class.perform_now(Submission.find(submission.id))
    expect(submission.reload).to be_failed
    expect(JSON.parse(submission.extracted_text)).to eq(JSON.parse(valid_result))
    expect(reader).to have_received(:call).once
    expect(AnswerGradingJob).to have_received(:perform_later).once
  end
end
