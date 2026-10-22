require "digest"
require "json"
require "securerandom"
require "stringio"

module Demo
  # Executed only by the explicit operator task; boot/eager loading performs no writes.
  class Seed
    class UnsafeTarget < StandardError; end
    MODELS = [ School, Admin, Teacher, Classroom, Student, TeacherClassroom,
      Assignment, AssignmentClassroom, Question, Submission, GradingResult, AnswerDraft ].freeze
    EXTRA_MODELS = [ QuestionGenerationRequest, ActiveStorage::Blob, ActiveStorage::Attachment,
      ActiveStorage::VariantRecord, AuthenticationAttemptBucket ].freeze
    TABLE_MODELS = (MODELS + EXTRA_MODELS).freeze
    LABEL = "架空のサンプル"

    def initialize(env: ENV)
      @env = env
    end

    def call
      guard!
      @manifest = nil
      verify_inventory!
      File.open(@root.join(".seed.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        refuse!("Seed already running") unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        ApplicationRecord.transaction do
          connection.execute(<<~SQL)
            LOCK TABLE schools, admins, teachers, classrooms, students, teacher_classrooms,
              assignments, assignment_classrooms, question_generation_requests, questions, submissions, grading_results,
              answer_drafts, active_storage_blobs, active_storage_attachments,
              active_storage_variant_records, authentication_attempt_buckets IN EXCLUSIVE MODE NOWAIT
          SQL
          if @root.join(".seed-manifest.json").exist?
            verify!
            refuse!("Demo data changed; no repair performed") unless snapshot == JSON.parse(@root.join(".seed-manifest.json").read)
          else
            refuse!("Expected an empty dedicated database") if TABLE_MODELS.any?(&:exists?)
            refuse!("Storage is not empty") unless Dir.children(@root).sort == %w[.demo-isolation .seed.lock]
            create!
            verify!
            @manifest = snapshot
          end
        end
        # A crash between DB commit and manifest persistence fails closed on rerun.
        if @manifest
          File.open(@root.join(".seed-manifest.json"), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            file.write(JSON.generate(@manifest))
            file.flush
            file.fsync
          end
        end
      end
      MODELS.to_h { |model| [ model.table_name, model.count ] }
    end

    # Never seeds, repairs, resets credentials or creates lock files.
    # Authentication counters/session revocations are intentionally mutable internal state.
    def verify_guest!
      guard!
      verify_inventory!
      refuse!("Missing seed manifest") unless @root.join(".seed-manifest.json").file?
      File.open(@root.join(".seed.lock"), File::RDONLY) do |lock|
        refuse!("Seed already running") unless lock.flock(File::LOCK_SH | File::LOCK_NB)
        expected = JSON.parse(@root.join(".seed-manifest.json").read)
        actual = snapshot
        [ expected, actual ].each { |value| value.fetch("tables").delete(AuthenticationAttemptBucket.table_name) }
        refuse!("Demo data changed: #{actual.fetch("tables").keys.select { |name| actual["tables"][name] != expected["tables"][name] }.join(",")}") unless actual == expected
      end
      true
    end

    private

    def verify_inventory!
      expected_tables = TABLE_MODELS.map(&:table_name) + %w[schema_migrations ar_internal_metadata]
      # connection.tables is search_path-limited. Inspect every user namespace,
      # including empty ones, and reject hidden tables/views without reading data.
      inventory = connection.select_rows(<<~SQL)
        SELECT namespaces.nspname, relations.relname
        FROM pg_namespace AS namespaces
        LEFT JOIN pg_class AS relations ON relations.relnamespace = namespaces.oid
          AND relations.relkind IN ('r', 'p', 'f', 'm', 'v')
        WHERE namespaces.nspname <> 'information_schema'
          AND (namespaces.nspname !~ '^pg_'
            OR (namespaces.nspname ~ '^pg_temp_[0-9]+$' AND relations.oid IS NOT NULL))
      SQL
      unexpected = inventory.any? do |schema, table|
        schema != "public" || (table.present? && !expected_tables.include?(table))
      end
      refuse!("Unexpected database schemas or tables") if unexpected
      refuse!("Storage contains symbolic links") if @root.glob("**/*", File::FNM_DOTMATCH).any?(&:symlink?)
    end

    def connection
      ApplicationRecord.connection
    end

    def refuse!(message)
      raise UnsafeTarget, message
    end

    def guard!
      refuse!("Demo seed disabled") unless @env["QUICKFLOW_DEMO_SEED"] == "true"
      refuse!("Only test environment is supported") unless Rails.env.test?
      token = @env["QUICKFLOW_DEMO_ISOLATION_ID"].to_s
      refuse!("Missing isolation ID") unless token.match?(/\A[0-9a-f]{32}\z/)
      actual = connection.select_one("SELECT current_database() AS database, host(inet_server_addr()) AS host, inet_server_port()::text AS port, shobj_description(oid, 'pg_database') AS marker FROM pg_database WHERE datname = current_database()")
      expected = { "database" => @env["QUICKFLOW_DEMO_DATABASE"], "host" => "127.0.0.1", "port" => @env["QUICKFLOW_DEMO_PORT"], "marker" => "quickflow-demo:#{token}" }
      refuse!("Actual database endpoint or isolation marker differs") unless actual == expected && actual["database"] == "quickflow_test" && actual["port"].to_i.between?(1024, 65535) && actual["port"] != "5432"
      config = ApplicationRecord.connection_db_config.configuration_hash
      refuse!("Database configuration differs") unless config[:host] == "127.0.0.1" && config[:port].to_s == actual["port"] && config[:database] == actual["database"]
      service = ActiveStorage::Blob.services.fetch("demo_seed")
      refuse!("Dedicated Disk storage required") unless service.instance_of?(ActiveStorage::Service::DiskService)
      @root = Rails.root.join("tmp", "demo-seed-#{token}")
      refuse!("Storage directory missing or redirected") unless @root.directory? && @root.realpath == @root && Pathname.new(service.root).expand_path == @root
      refuse!("Storage isolation marker differs") unless @root.join(".demo-isolation").file? && @root.join(".demo-isolation").read == token
    end

    def create!
      5.times do |index|
        number = index + 1
        school = School.create!(school_code: "DEMO#{number}")
        Admin.create!(school: school, user_id: "demo-admin-#{number}", password: SecureRandom.hex(24))
        teacher = Teacher.create!(school: school, user_id: "demo-teacher-#{number}", password: SecureRandom.hex(24))
        classroom = Classroom.create!(school: school, grade: 1, class_number: 1)
        TeacherClassroom.create!(teacher: teacher, classroom: classroom)
        student = Student.create!(classroom: classroom, attendance_number: 1, password: SecureRandom.hex(24))
        draft_student = Student.create!(classroom: classroom, attendance_number: 2, password: SecureRandom.hex(24))
        assignment = Assignment.create!(teacher: teacher, title: "#{LABEL} #{number}", point_per_question: 10, published_at: Time.current)
        attach!(assignment, :material_file, "material-#{number}.pdf", "1. Calculate 3x + 2x. Answer: ______")
        AssignmentClassroom.create!(assignment: assignment, classroom: classroom)
        question = Question.create!(assignment: assignment, question_label: "1", position: 1,
          question_text: "#{LABEL}: 3x+2x", correct_answer: "5x",
          grading_rule: JSON.generate(criteria: "#{LABEL}: 同類項をまとめる", requires_work: false, material_blob_id: assignment.material_file.blob.id),
          answer_generation_model: "demo-sample-no-ai", answer_generation_prompt_version: "demo-sample-v1", answer_generated_at: Time.current)
        submission = Submission.create!(assignment: assignment, student: student, status: :completed, submitted_at: Time.current,
          extracted_text: JSON.generate(problems: [ { question_label: "1", question_text: question.question_text,
            student_answer: "5x", reading_status: "readable", reading_reason: LABEL } ]))
        attach!(submission, :answer_file, "answer-#{number}.pdf", "1. Calculate 3x + 2x. Sample answer: 5x")
        GradingResult.create!(submission: submission, question: question, student_answer: "5x", ai_judgment: :correct,
          ai_model_name: "demo-sample-no-ai", prompt_version: "demo-sample-v1", graded_at: Time.current, feedback: LABEL)
        AnswerDraft.create!(assignment: assignment, student: draft_student,
          material_fingerprint: AnswerDraftContext.fingerprint(assignment), format_version: 1,
          page_data: [ { page_number: 1, operations: [ { id: 1, tool: "pen", color: "#000000", width: 1.2, points: [ [ 30, 100 ], [ 50, 110 ] ] } ] } ])
      end
    end

    def attach!(record, name, filename, text)
      bytes = pdf(text)
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename,
        content_type: "application/pdf", service_name: "demo_seed", identify: false,
        metadata: { identified: true, analyzed: true, demo_sample: true })
      record.public_send(name).attach(blob)
      # Active Storage schedules a deferred parent touch. Persist it before the
      # manifest; a later commit callback must not change the recorded timestamp.
      record.touch
    end

    # One-page PDF with a real cross-reference table; ASCII label is visible in all viewers.
    def pdf(text)
      stream = "BT /F1 12 Tf 40 760 Td (FICTIONAL DEMO SAMPLE - NO AI / NO REAL STUDENT) Tj 0 -30 Td (#{text}) Tj ET\n"
      objects = [ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", "<< /Length #{stream.bytesize} >>\nstream\n#{stream}endstream" ]
      result = +"%PDF-1.4\n"
      offsets = objects.each_with_index.map do |object, index|
        offset = result.bytesize
        result << "#{index + 1} 0 obj\n#{object}\nendobj\n"
        offset
      end
      xref = result.bytesize
      result << "xref\n0 6\n0000000000 65535 f \n"
      offsets.each { |offset| result << format("%010d 00000 n \n", offset) }
      result << "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    end

    def verify!
      MODELS.each do |model|
        refuse!("Unexpected count: #{model.table_name}") unless model.count == (model == Student ? 10 : 5)
        model.find_each { |record| refuse!("Invalid model: #{model.table_name}") unless record.valid? }
      end
      refuse!("Synthetic samples must have no generation history") if QuestionGenerationRequest.exists? || Assignment.where.not(current_question_generation_request_id: nil).exists?
      refuse!("Unexpected infrastructure records") if AuthenticationAttemptBucket.exists? || ActiveStorage::VariantRecord.exists?
      refuse!("Unexpected attachments") unless ActiveStorage::Blob.count == 10 && ActiveStorage::Attachment.count == 10
      Assignment.find_each { |assignment| QuestionGenerator.new.saved_questions(assignment) }
      Submission.find_each do |submission|
        AnswerGrader.reading_problems(submission.extracted_text)
        refuse!("Invalid sample score") unless submission.score == 10
      end
      AnswerDraft.find_each do |draft|
        refuse!("Draft context mismatch") unless draft.material_fingerprint == AnswerDraftContext.fingerprint(draft.assignment) && !Submission.exists?(student: draft.student, assignment: draft.assignment)
      end
      ActiveStorage::Blob.find_each do |blob|
        refuse!("Unexpected storage service") unless blob.service_name == "demo_seed"
        blob.open do |file|
          refuse!("Invalid sample PDF") unless Marcel::MimeType.for(file) == "application/pdf" && file.read.start_with?("%PDF-1.4")
        end
      end
    end

    def snapshot
      tables = TABLE_MODELS.to_h do |model|
        data = model.order(model.primary_key).map do |record|
          record.attributes.transform_values { |value| value.respond_to?(:usec) ? value.iso8601(6) : value }
        end
        [ model.table_name, Digest::SHA256.hexdigest(JSON.generate(data)) ]
      end
      files = @root.glob("**/*", File::FNM_DOTMATCH).select(&:file?).reject { |path| [ @root.join(".seed.lock"), @root.join(".seed-manifest.json") ].include?(path) }
      { "tables" => tables, "files" => files.sort.to_h { |path| [ path.relative_path_from(@root).to_s, Digest::SHA256.file(path).hexdigest ] } }
    end
  end
end
