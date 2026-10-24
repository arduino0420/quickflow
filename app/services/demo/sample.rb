require "digest"

module Demo
  # Owner-supplied, visually privacy-reviewed PDFs. Results below are manually
  # transcribed display fixtures, never an AI execution or a real pupil's grade.
  module Sample
    TITLE = "サンプルの小テスト"
    FILES = {
      material: [ "material.pdf", "8c280e1fb87e6cbc974ae4b95cdeebc06a9601f68d0ab73f7a1d21ec33ac22d3" ],
      answer: [ "answer.pdf", "37a7a5e024524cd8f93c6580680e596bc511ba243ed2eed0e315c98ff2f96eb8" ]
    }.freeze
    # label, problem, correct answer, supplied handwritten answer, display judgment
    QUESTIONS = [
      [ "1(1)", "−3−9", "−12", "−12", :correct ],
      [ "1(2)", "4−8+9−2", "3", "3", :correct ],
      [ "1(3)", "1−14+10−18", "−21", "−21", :correct ],
      [ "1(4)", "6−(−2)+9", "17", "17", :correct ],
      [ "1(5)", "−12−(−34)+0−21", "1", "−67", :incorrect ],
      [ "1(6)", "−3+(−8)−(−5)+(−7)", "−13", "−13", :correct ],
      [ "2(1)", "−0.8−2.4−0.3", "−3.5", "−3.5", :correct ],
      [ "2(2)", "4.8−6.4−(−2.1)", "0.5", "−3.7", :incorrect ],
      [ "2(3)", "1−2/3+5/6−1/2", "2/3", "4/6", :correct ],
      [ "2(4)", "−2/3−(−1/4)+1/6", "−1/4", "−1/4", :correct ]
    ].map(&:freeze).freeze

    def self.bytes(kind)
      filename, checksum = FILES.fetch(kind)
      bytes = Rails.root.join("db/demo_samples", filename).binread
      raise Seed::UnsafeTarget, "Sample PDF checksum differs" unless Digest::SHA256.hexdigest(bytes) == checksum
      bytes
    end
  end
end
