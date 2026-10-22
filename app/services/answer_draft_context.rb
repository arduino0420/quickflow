# A signed editor context prevents an old tab saving one student's ink into a new
# student's session, and binds both source PDF delivery and drafts to one material.
class AnswerDraftContext
  def self.fingerprint(assignment)
    return unless assignment.material_file.attached?

    blob = assignment.material_file.blob
    Digest::SHA256.hexdigest([ blob.id, blob.checksum, blob.byte_size ].join(":"))
  end

  def self.issue(student, assignment)
    verifier.generate([ student.id, assignment.id, fingerprint(assignment) ], purpose: "answer-draft")
  end

  def self.issue_recovery(student, assignment)
    verifier.generate([ student.id, student.classroom_id, student.classroom.school_id,
      assignment.id, fingerprint(assignment) ], purpose: "answer-draft-recovery")
  end

  def self.valid_recovery?(token, student, assignment)
    verifier.verified(token.to_s, purpose: "answer-draft-recovery") ==
      [ student.id, student.classroom_id, student.classroom.school_id,
        assignment.id, fingerprint(assignment) ] && fingerprint(assignment).present?
  end

  def self.valid?(token, student, assignment)
    verifier.verified(token.to_s, purpose: "answer-draft") == [ student.id, assignment.id, fingerprint(assignment) ] &&
      fingerprint(assignment).present?
  end

  def self.verifier
    Rails.application.message_verifier("answer-draft-context")
  end
end
