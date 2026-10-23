require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe SubmissionScores do
  include_context "AI grading records"

  before { assignment.assignment_classrooms.create!(classroom: classroom) }

  def result_for(question, value = :correct)
    submission.grading_results.create!(question: question, ai_judgment: value,
      ai_model_name: "synthetic", prompt_version: "v1", graded_at: Time.current)
  end

  def scores(items = [ submission ])
    described_class.new.call(items)
  end

  it "matches public scoring for teacher overrides, needs_review, unknown judgments and integer maximum scores" do
    submission.update!(status: :completed)
    questions = 4.times.map { |i| create_question(position: i + 1) }
    results = questions.map { |q| result_for(q) }
    results[0].update!(teacher_judgment: :incorrect)
    results[1].update!(ai_judgment: :needs_review, teacher_judgment: :correct)
    results[2].update_columns(ai_judgment: 99)
    results[3].update!(ai_judgment: :needs_review)
    expect(scores.fetch(submission.id)).to eq(5)
    expect(scores.fetch(submission.id)).to eq(submission.score)
    results.each { |r| r.update_columns(ai_judgment: 1, teacher_judgment: nil) }
    expect(scores.fetch(submission.id)).to eq(20)
    expect(scores.fetch(submission.id)).to be_a(Integer)
  end

  it "reads fresh results and questions despite stale preloads and reuse of the service" do
    submission.update!(status: :completed)
    result = result_for(create_question)
    submission.grading_results.load
    assignment.questions.load
    calculator = described_class.new
    expect(calculator.call([ submission ])[submission.id]).to eq(5)
    GradingResult.find(result.id).update!(teacher_judgment: :incorrect)
    expect(calculator.call([ submission ])[submission.id]).to eq(0)
    expect(submission.score).to eq(0)
    create_question(position: 2)
    expect(calculator.call([ submission ])[submission.id]).to be_nil
    expect(submission.score).to be_nil
  end

  [ :missing, :extra, :mismatched ].each do |condition|
    it "requires the exact question IDs for #{condition} results" do
      submission.update!(status: :completed)
      questions = [ create_question, create_question(position: 2) ]
      result_for(questions.first)
      result_for(questions.last) unless condition == :missing || condition == :mismatched
      unless condition == :missing
        other = Assignment.create!(teacher: teacher, title: "Foreign", point_per_question: 100)
        foreign = create_question(owner: other)
        result = submission.grading_results.build(question: foreign, ai_judgment: :correct,
          ai_model_name: "synthetic", prompt_version: "v1", graded_at: Time.current)
        result.save!(validate: false) # Historical mismatched result, never filter it away.
      end
      expect(scores.fetch(submission.id)).to be_nil
      expect(submission.score).to be_nil
    end
  end

  it "keeps empty questions and incomplete submissions distinct from a genuine zero" do
    submission.update!(status: :completed)
    expect(scores.fetch(submission.id)).to be_nil
    result_for(create_question, :incorrect)
    expect(scores.fetch(submission.id)).to eq(0)
    [ :submitted, :grading, :failed ].each do |status|
      submission.update!(status: status)
      expect(scores).to eq({})
    end
    expect(scores([ Submission.new(status: :completed) ])).to eq({})
    expect(scores([])).to eq({})
  end

  it "separates assignments and students and leaves persisted records unchanged" do
    submission.update!(status: :completed)
    result_for(create_question)
    other = Assignment.create!(teacher: teacher, title: "Other", point_per_question: 7)
    other.assignment_classrooms.create!(classroom: classroom)
    item = Submission.create!(assignment: other, student: student, status: :completed, submitted_at: Time.current)
    item.grading_results.create!(question: create_question(owner: other), ai_judgment: :correct,
      ai_model_name: "synthetic", prompt_version: "v1", graded_at: Time.current)
    original = [ submission, item ].map(&:attributes)
    original_results = GradingResult.order(:id).map(&:attributes)
    expect(scores([ submission, item ])).to eq(submission.id => 5, item.id => 7)
    expect([ submission, item ].map { |s| s.reload.attributes }).to eq(original)
    expect(GradingResult.order(:id).map(&:attributes)).to eq(original_results)
  end
end
