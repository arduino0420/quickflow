require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe AnswerGrader, type: :model do
  include_context "AI grading records"

  let(:question) { create_question }
  let(:grader) { described_class.new(client: client, model: "configured-grading-model") }

  before do
    allow(responses).to receive(:create).and_return(ai_response(results: [ judgment(question) ]))
  end

  it "grades all readable questions in a single text request and keeps the original answer" do
    second = create_question(position: 2, label: "1(2)", text: "x+x を計算しなさい。", answer: "2x")
    second_problem = problem.merge(question_label: second.question_label, question_text: second.question_text, student_answer: "x*2")
    submission.update!(extracted_text: JSON.generate(problems: [ second_problem, problem ]))
    allow(responses).to receive(:create).and_return(ai_response(
      { results: [ judgment(second), judgment(question).merge(student_answer: "AI changed this") ] }, model: "actual-grading-model"))

    results = grader.call(submission, [ question, second ])

    expect(results.map { |result| result[:student_answer] }).to eq([ "5x", "x*2" ])
    expect(results.map { |result| result[:ai_model_name] }).to eq([ "actual-grading-model", "actual-grading-model" ])
    expect(results.all? { |result| result[:prompt_version] == described_class::PROMPT_VERSION && result[:graded_at].present? }).to be(true)
    expect(responses).to have_received(:create).once do |request|
      expect(request[:model]).to eq("configured-grading-model")
      expect(request[:store]).to be(false)
      input = JSON.parse(request[:input])["problems"]
      expect(input.map { |item| item["question_id"] }).to eq([ question.id, second.id ])
      expect(input.map { |item| item["student_answer"] }).to eq([ "5x", "x*2" ])
      expect(input.map { |item| item["question_label"] }).to eq([ "1(1)", "1(2)" ])
      expect(input.map { |item| item["correct_answer"] }).to eq([ "5x", "2x" ])
      expect(input.all? { |item| item["grading_rule"] == "同類項をまとめる。" && item["requires_work"] == false }).to be(true)
      expect(input.none? { |item| item.key?("question_text") }).to be(true)
      expect(request[:instructions]).to include("数学的に同値", "未約分", "補正・推測しない")
    end
    expect(files).not_to receive(:create)
  end

  it "saves the AI's incorrect judgment and short feedback" do
    submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(student_answer: "-5x") ]))
    allow(responses).to receive(:create).and_return(ai_response(results: [
      judgment(question, value: "incorrect", error_point: "符号が違います。", feedback: "符号を確認しましょう。")
    ]))
    result = grader.call(submission, [ question ]).first
    expect(result).to include(ai_judgment: "incorrect", student_answer: "-5x", feedback: "符号を確認しましょう。")
  end

  it "grades by a unique label despite whitespace differences in question text" do
    submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(question_text: "3x + 2x\nを計算しなさい。") ]))
    expect(grader.call(submission, [ question ]).first[:ai_judgment]).to eq("correct")
    expect(responses).to have_received(:create).once
  end

  it "batches normalized answers unchanged without rewriting saved inputs or results" do
    question.update!(question_label: "2①")
    second = create_question(position: 2, label: "2②")
    submission.update!(extracted_text: JSON.generate(problems: [
      problem.merge(question_label: "2 (2)", student_answer: " x + x "), problem.merge(question_label: "2(1)")
    ]))
    reading_before = submission.extracted_text
    questions_before = assignment.questions.order(:id).map(&:attributes)
    allow(responses).to receive(:create).and_return(ai_response(results: [ judgment(second), judgment(question) ]))

    expect { grader.call(submission, [ question, second ]) }.not_to change(GradingResult, :count)
    expect(responses).to have_received(:create).once do |request|
      input = JSON.parse(request[:input]).fetch("problems")
      expect(input.map { |item| item.values_at("question_id", "question_label", "student_answer") }).to eq([
        [ question.id, "2①", "5x" ], [ second.id, "2②", " x + x " ]
      ])
    end
    expect(submission.reload.extracted_text).to eq(reading_before)
    expect(assignment.questions.order(:id).map(&:attributes)).to eq(questions_before)
  end

  it "grades a standalone format difference only for a wholly standalone material list" do
    question.update!(question_label: "①")
    submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(question_label: "(1)") ]))
    expect(grader.call(submission, [ question ]).first[:ai_judgment]).to eq("correct")
    expect(responses).to have_received(:create).once
  end

  it "requires review for a standalone format difference in mixed material while keeping safe grouped matches" do
    question.update!(question_label: "①")
    second = create_question(position: 2, label: "2①")
    submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(question_label: "(1)"), problem.merge(question_label: "2(1)") ]))
    allow(responses).to receive(:create).and_return(ai_response(results: [ judgment(second) ]))
    results = grader.call(submission, [ question, second ])
    expect(results.find { |result| result[:question] == question }).to include(ai_judgment: "needs_review", student_answer: nil)
    expect(responses).to have_received(:create).once do |request|
      expect(JSON.parse(request[:input]).fetch("problems").map { |item| item.fetch("question_id") }).to eq([ second.id ])
    end
  end

  [ :reading, :material ].each do |side|
    it "does not prefer an exact match over a normalized #{side} collision" do
      question.update!(question_label: "2①")
      second = create_question(position: 2, label: "3①")
      colliding = create_question(position: 3, label: "2(1)") if side == :material
      readings = [ problem.merge(question_label: "2①"), problem.merge(question_label: "3(1)") ]
      readings << problem.merge(question_label: "2(1)") if side == :reading
      submission.update!(extracted_text: JSON.generate(problems: readings))
      allow(responses).to receive(:create).and_return(ai_response(results: [ judgment(second) ]))
      results = grader.call(submission, [ question, second, colliding ].compact)
      expect(results.reject { |result| result[:question] == second }).to all(include(ai_judgment: "needs_review", student_answer: nil))
      expect(responses).to have_received(:create).once do |request|
        expect(JSON.parse(request[:input]).fetch("problems").map { |item| item.fetch("question_id") }).to eq([ second.id ])
      end
    end
  end

  [ "blank", "unclear", "ambiguous", "unavailable" ].each do |status|
    it "keeps the existing #{status} policy after normalized matching" do
      question.update!(question_label: "2①")
      submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(
        question_label: "2(1)", reading_status: status, student_answer: nil, reading_reason: "確認が必要です。") ]))
      result = grader.call(submission, [ question ]).first
      expect(result).to include(ai_judgment: status == "blank" ? "incorrect" : "needs_review", student_answer: nil, ai_model_name: "local-rules")
      expect(responses).not_to have_received(:create)
    end
  end

  [ { reading_status: "readable", student_answer: nil }, { reading_status: "blank", student_answer: "5x" } ].each do |change|
    it "keeps inconsistent reading states under review after normalization #{change.inspect}" do
      question.update!(question_label: "2①")
      submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(question_label: "2(1)", **change) ]))
      expect(grader.call(submission, [ question ]).first).to include(ai_judgment: "needs_review", review_reason: "読み取り状態と最終解答が一致しません。")
      expect(responses).not_to have_received(:create)
    end
  end

  it "does not treat a missing major number as a confirmed blank" do
    question.update!(question_label: "2①")
    submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(question_label: "①", reading_status: "blank", student_answer: nil) ]))
    expect(grader.call(submission, [ question ]).first).to include(ai_judgment: "needs_review", student_answer: nil)
    expect(responses).not_to have_received(:create)
  end

  it "does not infer required work or a correct answer after matching labels" do
    question.update!(question_label: "2①", grading_rule: JSON.generate(criteria: "式も確認する。", requires_work: true))
    submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(question_label: "2(1)") ]))
    expect(grader.call(submission, [ question ]).first[:review_reason]).to eq("指定解法・途中式を読み取り結果から確認できません。")
    expect(responses).not_to have_received(:create)
  end

  it "still rejects duplicate original material labels before matching" do
    second = create_question(position: 2, label: question.question_label)
    expect { grader.call(submission, [ question, second ]) }.to raise_error("Invalid questions for submission")
    expect(responses).not_to have_received(:create)
  end

  [ nil, "", "別の問題", "3x-2x を計算しなさい。", "次の計算をしなさい。\n3x+2x" ].each do |text|
    it "grades a unique label without comparing printed text #{text.inspect}" do
      submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(question_text: text) ]))
      expect(grader.call(submission, [ question ]).first[:ai_judgment]).to eq("correct")
      expect(responses).to have_received(:create).once
    end
  end

  it "keeps AI uncertainty as needs_review with its reason" do
    allow(responses).to receive(:create).and_return(ai_response(results: [
      judgment(question, value: "needs_review", review_reason: "採点条件の解釈を確認してください。")
    ]))
    expect(grader.call(submission, [ question ]).first).to include(ai_judgment: "needs_review", review_reason: "採点条件の解釈を確認してください。")
  end

  %w[unclear ambiguous unavailable].each do |status|
    it "forces #{status} to needs_review without asking the AI" do
      submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(reading_status: status, reading_reason: "判読不能", student_answer: nil) ]))
      result = grader.call(submission, [ question ]).first
      expect(result).to include(ai_judgment: "needs_review", review_reason: "判読不能", ai_model_name: "local-rules", reading_confidence: nil)
      expect(responses).not_to have_received(:create)
    end
  end

  it "judges a confirmed blank as incorrect without an API request" do
    submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(reading_status: "blank", student_answer: nil) ]))
    result = grader.call(submission, [ question ]).first
    expect(result).to include(ai_judgment: "incorrect", student_answer: nil, ai_model_name: "local-rules")
    expect(result[:feedback]).to be_present
    expect(responses).not_to have_received(:create)
  end

  it "only sends eligible problems when readable and unclear answers are mixed" do
    second = create_question(position: 2, label: "1(2)")
    submission.update!(extracted_text: JSON.generate(problems: [ problem, problem.merge(question_label: "1(2)", reading_status: "ambiguous") ]))
    results = grader.call(submission, [ question, second ])
    expect(results.find { |result| result[:question] == second }[:ai_judgment]).to eq("needs_review")
    expect(responses).to have_received(:create).once do |request|
      expect(JSON.parse(request[:input])["problems"].map { |item| item["question_id"] }).to eq([ question.id ])
    end
  end

  [ { question_label: nil }, { question_label: "" }, { question_label: "9" }, { question_label: "1(?)" },
    { student_answer: nil }, { reading_status: "blank", student_answer: "5x" } ].each do |change|
    it "requires review for unsafe matching or inconsistent reading #{change.inspect}" do
      submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(change) ]))
      result = grader.call(submission, [ question ]).first
      expect(result[:ai_judgment]).to eq("needs_review")
      expect(result[:review_reason]).to be_present
      expect(responses).not_to have_received(:create)
    end
  end

  it "does not guess which duplicate answer belongs to a question" do
    submission.update!(extracted_text: JSON.generate(problems: [ problem, problem.merge(student_answer: "3x") ]))
    expect(grader.call(submission, [ question ]).first[:ai_judgment]).to eq("needs_review")
    expect(responses).not_to have_received(:create)
  end

  it "does not assign an unmatched answer to a missing question by order" do
    second = create_question(position: 2, label: "1(2)")
    submission.update!(extracted_text: JSON.generate(problems: [
      problem.merge(question_label: "9", student_answer: "FOREIGN ANSWER"), problem
    ]))
    results = grader.call(submission, [ question, second ])
    expect(results.find { |result| result[:question] == second }).to include(ai_judgment: "needs_review", student_answer: nil)
    expect(responses).to have_received(:create).once do |request|
      input = JSON.parse(request[:input]).fetch("problems")
      expect(input.size).to eq(1)
      expect(input.first).to include("question_label" => "1(1)", "student_answer" => "5x")
    end
  end

  it "grades only the uniquely matched answer when another label is duplicated" do
    second = create_question(position: 2, label: "1(2)")
    submission.update!(extracted_text: JSON.generate(problems: [
      problem.merge(question_label: "1(2)"), problem, problem.merge(question_label: "1(2)", student_answer: "3x")
    ]))
    results = grader.call(submission, [ question, second ])
    expect(results.find { |result| result[:question] == second }[:ai_judgment]).to eq("needs_review")
    expect(responses).to have_received(:create).once do |request|
      expect(JSON.parse(request[:input]).fetch("problems").map { |item| item.fetch("question_label") }).to eq([ "1(1)" ])
    end
  end

  it "passes the ten-question scenario in one stubbed request without regenerating or saving results" do
    examples = [
      [ "1(1)", "−3−9", "−12", "−12" ], [ "1(2)", "4−8＋9−2", "3", "3" ],
      [ "1(3)", "1−14＋10−18", "−21", "−21" ], [ "1(4)", "6−(−2)＋9", "17", "17" ],
      [ "1(5)", "−12−(−34)＋0−21", "1", "−67" ], [ "1(6)", "−3＋(−8)−(−5)＋(−7)", "−13", "−13" ],
      [ "2(1)", "−0.8−2.4−0.3", "−3.5", "−3.5" ], [ "2(2)", "4.8−6.4−(−2.1)", "0.5", "−3.7" ],
      [ "2(3)", "1−2/3＋5/6−1/2", "2/3", "4/6" ], [ "2(4)", "−2/3−(−1/4)＋1/6", "−1/4", "−1/4" ]
    ]
    questions = examples.each_with_index.map do |(label, text, answer, _), index|
      if index.zero?
        question.update!(question_text: "次の計算をしなさい。\n#{text}", correct_answer: answer)
        question
      else
        create_question(position: index + 1, label: label, text: "次の計算をしなさい。\n#{text}", answer: answer)
      end
    end
    problems = examples.map do |label, text, _, answer|
      problem.merge(question_label: label, question_text: "#{text} を計算しなさい。", student_answer: answer)
    end
    submission.update!(extracted_text: JSON.generate(problems: problems.reverse))
    original_reading = submission.extracted_text
    # These are mathematical expectations supplied as fake AI results, not real API judgments.
    incorrect_labels = %w[1(5) 2(2) 2(3)]
    judgments = questions.map do |item|
      if incorrect_labels.include?(item.question_label)
        judgment(item, value: "incorrect", error_point: "計算または約分が未完了。", feedback: "符号と約分を確認しましょう。")
      else
        judgment(item)
      end
    end
    allow(responses).to receive(:create).and_return(ai_response(results: judgments.reverse))
    expect(QuestionGenerator).not_to receive(:new)
    expect(AnswerReader).not_to receive(:new)
    expect(files).not_to receive(:create)

    results = grader.call(submission, questions)
    expect(results.map { |result| result[:ai_judgment] }.tally).to eq("correct" => 7, "incorrect" => 3)
    expect(results.map { |result| result[:student_answer] }).to eq(examples.map(&:last))
    expect(submission.reload.extracted_text).to eq(original_reading)
    expect(submission.grading_results).to be_empty
    expect(responses).to have_received(:create).once do |request|
      input = JSON.parse(request[:input]).fetch("problems")
      expect(input.map { |item| item.fetch("question_label") }).to eq(examples.map(&:first))
      expect(input.size).to eq(10)
      expect(input.all? { |item| item["requires_work"] == false }).to be(true)
    end
  end

  it "requires review for a missing answer while grading the matched answer" do
    second = create_question(position: 2, label: "1(2)")
    results = grader.call(submission, [ question, second ])
    expect(results.find { |result| result[:question] == second }[:ai_judgment]).to eq("needs_review")
  end

  it "requires review when necessary intermediate work is unavailable" do
    question.update!(grading_rule: JSON.generate(criteria: "指定解法を使う。", requires_work: true))
    expect(grader.call(submission, [ question ]).first[:review_reason]).to include("途中式")
    expect(responses).not_to have_received(:create)
  end

  [ nil, "従来の条件テキスト", '{"criteria":"test"}' ].each do |rule|
    it "conservatively handles old or incomplete grading rules #{rule.inspect}" do
      question.update!(grading_rule: rule)
      expect(grader.call(submission, [ question ]).first[:ai_judgment]).to eq("needs_review")
      expect(responses).not_to have_received(:create)
    end
  end

  [ "bad JSON", { problems: [] }.to_json, { problems: [ { question_label: "1" } ] }.to_json,
    { problems: [ { question_label: 1, question_text: nil, student_answer: nil, reading_reason: nil, reading_status: "readable" } ] }.to_json ].each do |text|
    it "rejects malformed stored reading data #{text.inspect}" do
      submission.update!(extracted_text: text)
      expect { grader.call(submission, [ question ]) }.to raise_error(StandardError)
      expect(responses).not_to have_received(:create)
    end
  end

  it "rejects questions belonging to a different assignment" do
    other = Assignment.create!(teacher: teacher, title: "別のテスト", point_per_question: 5)
    foreign = create_question(owner: other)
    expect { grader.call(submission, [ foreign ]) }.to raise_error("Invalid questions for submission")
    expect(responses).not_to have_received(:create)
  end

  [ :missing, :duplicate, :foreign, :unknown_judgment, :no_reason, :no_feedback ].each do |invalid|
    it "rejects #{invalid} AI results rather than saving guessed judgments" do
      data = case invalid
      when :missing then []
      when :duplicate then [ judgment(question), judgment(question) ]
      when :foreign then [ judgment(question).merge(question_id: question.id + 1000) ]
      when :unknown_judgment then [ judgment(question, value: "unknown") ]
      when :no_reason then [ judgment(question, value: "needs_review") ]
      when :no_feedback then [ judgment(question, value: "incorrect") ]
      end
      allow(responses).to receive(:create).and_return(ai_response(results: data))
      expect { grader.call(submission, [ question ]) }.to raise_error("Invalid answer grading result")
      expect(responses).to have_received(:create).once
    end
  end
end
