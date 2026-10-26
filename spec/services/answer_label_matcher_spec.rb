require "rails_helper"

RSpec.describe AnswerLabelMatcher do
  def match_labels(labels, readings)
    questions = labels.map { |label| Struct.new(:question_label).new(label) }
    problems = readings.map.with_index { |label, index| { "question_label" => label, "student_answer" => "answer #{index}" } }
    matcher = described_class.new(questions, problems)
    questions.map { |question| matcher.match(question) }
  end

  (1..20).each do |minor|
    circled = ("①".ord + minor - 1).chr(Encoding::UTF_8)
    it "matches grouped and standalone circled #{minor} in both directions" do
      [ [ "2#{circled}", "2(#{minor})" ], [ circled, "(#{minor})" ] ].each do |left, right|
        expect(match_labels([ left ], [ right ]).sole).to include("question_label" => right)
        expect(match_labels([ right ], [ left ]).sole).to include("question_label" => left)
      end
    end
  end

  [ "2①", "2 ①", "2   ①", "2(1)", "2 (1)", "2   (1)" ].each do |label|
    it "accepts only the allowed spaces in #{label.inspect}" do
      expect(match_labels([ label ], [ "2①" ]).sole).to include("question_label" => "2①")
      expect(match_labels([ "2①" ], [ label ]).sole).to include("question_label" => label)
    end
  end

  [ "1", "1.", "２①", "2（1）", "2-1", "第2問①", "2(01)", "02①", "0①", "2(0)", "2(21)",
    "2㉑", "2(1)(1)", "2\t①", "2　①", "2\n①", " 2①", "2① ", "2①\n", "x2①", "2①x" ].each do |label|
    it "keeps unsupported #{label.inspect} exact without interpreting it" do
      expect(match_labels([ label ], [ label ]).sole).to include("question_label" => label)
      expect(match_labels([ label ], [ "2①", "①" ])).to eq([ nil ])
      expect(match_labels([ "2①", "①" ], [ label ])).to eq([ nil, nil ])
    end
  end

  [ nil, "", " ", "\t\n" ].each do |label|
    it "never uses invalid #{label.inspect} as a shared key" do
      expect(match_labels([ label ], [ label ])).to eq([ nil ])
      expect(match_labels([ "2①" ], [ label ])).to eq([ nil ])
    end
  end

  it "keeps kinds and major/minor numbers distinct even with only one candidate" do
    [ [ "2①", "①" ], [ "①", "2(1)" ], [ "2①", "3(1)" ], [ "2①", "2(2)" ],
      [ "2①", "21" ], [ "1", "①" ], [ "1.", "(1)" ] ].each do |left, right|
      expect(match_labels([ left ], [ right ])).to eq([ nil ])
      expect(match_labels([ right ], [ left ])).to eq([ nil ])
    end
  end

  it "does not infer standalone structure from a mixed or unsupported material list" do
    expect(match_labels([ "①", "2①" ], [ "(1)", "2(1)" ])).to match([ nil, hash_including("question_label" => "2(1)") ])
    expect(match_labels([ "①", "A" ], [ "(1)", "A" ])).to match([ nil, hash_including("question_label" => "A") ])
    expect(match_labels([ "①", "2①" ], [ "①", "2(1)" ])).to all(be_present)
  end

  it "checks both sides for collisions before exact matching and isolates unrelated labels" do
    [ [ "2①", "2①" ], [ "2①", "2(1)" ], [ "2①", "2 ①" ] ].each do |collision|
      expect(match_labels([ "2①", "3①" ], collision + [ "3(1)" ])).to match([ nil, hash_including("question_label" => "3(1)") ])
      expect(match_labels(collision + [ "3①" ], [ "2①", "3(1)" ])).to match([ nil, nil, hash_including("question_label" => "3(1)") ])
    end
  end

  it "rejects standalone collisions even when standalone normalization is disabled" do
    expect(match_labels([ "①", "2①" ], [ "①", "(1)", "2①" ])).to match([ nil, hash_including("question_label" => "2①") ])
    expect(match_labels([ "①", "(1)", "②" ], [ "①", "②" ])).to match([ nil, nil, hash_including("question_label" => "②") ])
    expect(match_labels([ "①", "(1)", "②" ], [ "①", "(2)" ])).to eq([ nil, nil, nil ])
  end

  it "does not pair missing or extra answers by position and is independent of reading order" do
    labels = [ "3②", "2①", "4①" ]
    readings = [ "2(1)", "9(1)", "3(2)" ]
    expected = [ hash_including("question_label" => "3(2)"), hash_including("question_label" => "2(1)"), nil ]
    expect(match_labels(labels, readings)).to match(expected)
    expect(match_labels(labels, readings.reverse)).to match(expected)
  end

  it "returns the same original reading without mutating any input" do
    question = Struct.new(:question_label).new("2①".freeze).freeze
    reading = { "question_label" => "2 (1)".freeze, "student_answer" => " x + x ".freeze }.freeze
    expect(described_class.new([ question ].freeze, [ reading ].freeze).match(question)).to equal(reading)
  end
end
