class AnswerLabelMatcher
  LABEL = /\A(?:(?<major>[1-9][0-9]*) *)?(?:(?<circled>[①-⑳])|\((?<minor>[1-9]|1[0-9]|20)\))\z/

  def initialize(questions, problems)
    @questions = questions.group_by { |question| key(question.question_label) }
    @problems = problems.group_by { |problem| key(problem["question_label"]) }
    @standalone = questions.any? && @questions.all? { |key, items| key&.first == :standalone && items.one? }
  end

  def match(question)
    label_key = key(question.question_label)
    return unless label_key && @questions.fetch(label_key, []).one?

    matches = @problems.fetch(label_key, [])
    # Detect structural collisions before considering even an exact match.
    return unless matches.one?
    return if label_key.first == :standalone && !@standalone && matches.first["question_label"] != question.question_label

    matches.first
  end

  private

  def key(label)
    return unless label.is_a?(String) && label.present?

    parsed = LABEL.match(label)
    return [ :exact, label ] unless parsed

    minor = parsed[:circled] ? parsed[:circled].ord - "①".ord + 1 : parsed[:minor].to_i
    parsed[:major] ? [ :grouped, parsed[:major], minor ] : [ :standalone, minor ]
  end
end
