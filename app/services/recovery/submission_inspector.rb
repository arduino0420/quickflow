module Recovery
  class SubmissionInspector
    UNCHECKED = [ "PDF実体の存在・内容", "失敗キャッシュ", "待機中・実行中Job", "失敗原因・採点時点の教材との一致" ].freeze

    def call(submission, observed_at: Time.current)
      assignment = submission.assignment
      reading = reading_state(submission.extracted_text)
      questions = question_state(assignment)
      results = submission.grading_results.to_a
      question_ids = assignment.questions.ids.sort
      matching = question_ids.any? && results.map(&:question_id).sort == question_ids
      answer_pdf = attachment_state(submission.answer_file_attachment)
      material_pdf = attachment_state(assignment.material_file_attachment)
      reasons = []
      reasons << "採点状態が既存の定義に適合しません。" unless submission.status.in?(Submission.statuses.keys)
      reasons << "答案PDFの添付情報が不足しています。" unless answer_pdf[:blob_record]
      reasons << "教材PDFの添付情報が不足しています。" unless material_pdf[:blob_record]
      reasons << "保存済み読み取り結果の形式が不正です。" if reading == "invalid"
      reasons << "保存済み正答が既存の検証基準に適合しません。" if questions == "invalid"
      reasons << "正答がありません。正答生成の確認が先に必要です。" if questions == "missing"
      reasons << "採点結果と現在の問題IDが一致しません。" if submission.completed? && !matching
      if results.any?
        reasons << (matching ? "全問分の結果が存在します。状態変更の安全性は未確認です。" : "採点結果が一部のみ、または現在の問題IDと一致しません。") unless submission.completed?
        reasons << "採点結果の必須情報・判定に不整合があります。" unless results.all? { |result| valid_result?(result) }
      end

      {
        submission_id: submission.id, assignment_id: assignment.id,
        status: submission.status, submitted_at: submission.submitted_at&.iso8601,
        updated_at: submission.updated_at.iso8601, observed_at: observed_at.iso8601,
        answer_pdf: answer_pdf, material_pdf: material_pdf,
        question_generation: generation_state(assignment),
        reading: reading, questions: questions, question_count: question_ids.size,
        result_count: results.size, result_question_ids_match: matching,
        teacher_judgment_present: results.any? { |result| result.teacher_judgment_before_type_cast.present? },
        classification: classification(submission, results, reasons, reading),
        reasons: reasons, unchecked: UNCHECKED,
        notice: "読み取り専用の観測結果です。復旧可否や処理停止を確定するものではありません。"
      }
    end

    private

    def generation_state(assignment)
      request = assignment.question_generation_requests.find_by(id: assignment.current_question_generation_request_id)
      return { state: "legacy_unknown" } unless request

      { request_id: request.id, state: request.state, input_matches: request.selected_input?(assignment),
        created_at: request.created_at.iso8601, started_at: request.started_at&.iso8601,
        finished_at: request.finished_at&.iso8601, failure_code: request.failure_code,
        notice: "経過時間だけでは処理停止を確定できません。DBの配信意図とキュー登録は別々の確定です。" }
    end

    def attachment_state(attachment)
      { attachment_record: attachment.present?, blob_record: attachment&.blob.present? }
    end

    def reading_state(text)
      return "missing" if text.blank?

      AnswerGrader.reading_problems(text)
      "valid"
    rescue JSON::ParserError, RuntimeError
      "invalid"
    end

    def question_state(assignment)
      # This path only validates saved questions; it never uses a model or client.
      QuestionGenerator.new(model: nil).saved_questions(assignment).any? ? "valid" : "missing"
    rescue RuntimeError, JSON::ParserError
      "invalid"
    end

    def valid_result?(result)
      result.ai_judgment.in?(GradingResult.ai_judgments.keys) &&
        (result.teacher_judgment_before_type_cast.nil? || result.teacher_judgment.in?(GradingResult.teacher_judgments.keys)) &&
        result.ai_model_name.present? && result.prompt_version.present? && result.graded_at.present? &&
        (!result.ai_judgment_incorrect? || (result.error_point.present? && result.feedback.present?)) &&
        (!result.ai_judgment_needs_review? || result.review_reason.present?)
    end

    def classification(submission, results, reasons, reading)
      return "完了済み（復旧対象外）" if submission.completed?
      return "既存結果の確認が必要" if results.any?
      return "追加確認が必要" if reasons.any?

      reading == "missing" ? "読み取り再開の検討対象" : "採点再開の検討対象"
    end
  end
end
