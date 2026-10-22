require "rails_helper"
require "tmpdir"

RSpec.describe "Teacher material upload safety", type: :request do
  include ActiveJob::TestHelper
  self.use_transactional_tests = false
  let(:school) { School.create!(school_code: "UPLOAD") }
  let(:teacher) { Teacher.create!(school: school, user_id: "upload-teacher", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1) }

  around do |example|
    Dir.mktmpdir("teacher-material-storage") do |root|
      original_service = ActiveStorage::Blob.service
      original_services = ActiveStorage::Blob.services
      @storage_root = root
      ActiveStorage::Blob.service = ActiveStorage::Service.configure(:test,
        { test: { service: "Disk", root: root } })
      ActiveStorage::Blob.services = { "test" => ActiveStorage::Blob.service }
      example.run
    ensure
      ActiveStorage::Blob.service = original_service
      ActiveStorage::Blob.services = original_services
    end
  end

  before do
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
    classroom
    @uploads = []
    allow(ActiveStorage::Blob).to receive(:build_after_unfurling).and_wrap_original do |method, **options|
      method.call(**options).tap do |blob|
        expect(blob.service.root.to_s).to eq(@storage_root)
        @uploads << blob
      end
    end
  end

  after do
    allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_call_original
    allow_any_instance_of(AssignmentClassroom).to receive(:save!).and_call_original
    teacher.assignments.each { |item| AssignmentDeletion.new.call(item, teacher: teacher) }
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
    @uploads.each do |upload|
      blob = ActiveStorage::Blob.find_by(id: upload.id)
      blob.purge if blob && !blob.attachments.exists?
    end
    TeacherClassroom.where(classroom: classroom).delete_all
    classroom.destroy!
    teacher.destroy!
    school.destroy!
    clear_enqueued_jobs
  end

  def post_material
    post assignments_path, params: { assignment: { title: "保存境界", point_per_question: "7",
      classroom_ids: [ classroom.id.to_s ],
      material_file: fixture_file_upload(Rails.root.join("spec/fixtures/files/material.pdf"), "application/pdf") } }
  end

  def counts
    [ Assignment.count, AssignmentClassroom.count, ActiveStorage::Attachment.count, ActiveStorage::Blob.count ]
  end

  def expect_no_file(blob)
    expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
    expect(blob.service.exist?(blob.key)).to be(false)
  end

  [ :before_write, :partial_write ].each do |stage|
    it "leaves no distribution after #{stage} failure and permits retry" do
      original_counts = counts
      fail_once = true
      allow_any_instance_of(ActiveStorage::Blob).to receive(:upload_without_unfurling).and_wrap_original do |method, *args|
        if fail_once
          fail_once = false
          method.receiver.service.upload(method.receiver.key, StringIO.new("%PDF-partial")) if stage == :partial_write
          raise IOError, "PRIVATE STORAGE DETAILS"
        end
        method.call(*args)
      end

      post_material

      expect(response).to have_http_status(:service_unavailable)
      expect(response.body).to include("教材PDFを保存できませんでした")
      expect(response.body).not_to include("PRIVATE STORAGE DETAILS", "小テストを配信しました")
      expect(counts).to eq(original_counts)
      persisted_counts = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { counts }
      end.value
      expect(persisted_counts).to eq(original_counts)
      expect(QuestionGenerationJob).not_to have_been_enqueued
      expect_no_file(@uploads.last)
      document = Nokogiri::HTML(response.body)
      expect(document.at_css('input[name="assignment[title]"]')[:value]).to eq("保存境界")
      expect(document.at_css('input[name="assignment[point_per_question]"]')[:value]).to eq("7")
      expect(document.at_css("input[type='checkbox'][value='#{classroom.id}']")[:checked]).to be_present
      expect(document.at_css("input[type='file']")[:value]).to be_blank
      expect(document.at_css("input[type='hidden'][name='assignment[material_file]']")).to be_nil

      post_material

      expect(response).to have_http_status(:see_other)
      saved = Assignment.last
      expect(saved.material_file.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
      expect(saved.classrooms).to contain_exactly(classroom)
      expect(QuestionGenerationJob).to have_been_enqueued.with(saved, saved.material_file.blob.id).exactly(:once)
    end
  end

  it "cleans only its uploaded blob after distribution rollback" do
    unrelated = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("keep"), filename: "keep.txt")
    existing = teacher.assignments.create!(title: "既存教材", point_per_question: 5)
    existing.material_file.attach(io: StringIO.new("existing"), filename: "existing.pdf", content_type: "application/pdf")
    original_counts = counts
    allow_any_instance_of(AssignmentClassroom).to receive(:save!).and_raise(
      ActiveRecord::RecordInvalid.new(AssignmentClassroom.new))

    post_material

    expect(response).to have_http_status(:unprocessable_entity)
    expect(counts).to eq(original_counts)
    expect(QuestionGenerationJob).not_to have_been_enqueued
    expect_no_file(@uploads.last)
    expect(unrelated.reload.download).to eq("keep")
    expect(existing.reload.material_file.download).to eq("existing")
  end

  it "preserves the storage failure response when cleanup also fails" do
    allow_any_instance_of(ActiveStorage::Blob).to receive(:upload_without_unfurling).and_raise(IOError, "PRIVATE upload")
    allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_raise(IOError, "PRIVATE cleanup")
    original_counts = counts

    post_material

    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).to include("教材PDFを保存できませんでした")
    expect(response.body).not_to include("PRIVATE")
    expect(counts.first(3)).to eq(original_counts.first(3))
    expect(@uploads.last.attachments).to be_empty
    expect(QuestionGenerationJob).not_to have_been_enqueued
  end

  it "retains the committed upload and distribution when generation enqueue raises" do
    allow(QuestionGenerationJob).to receive(:perform_later).and_raise(IOError, "PRIVATE queue")
    allow_any_instance_of(QuestionGenerator).to receive(:record_failure)

    post_material

    expect(response).to have_http_status(:see_other)
    saved = Assignment.last
    expect(saved.material_file.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
    expect(saved.classrooms).to contain_exactly(classroom)
    expect(ActiveStorage::Blob.exists?(@uploads.last.id)).to be(true)
    persisted = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Assignment.find(saved.id).material_file.download
      end
    end.value
    expect(persisted).to eq(saved.material_file.download)
    expect(QuestionGenerationJob).to have_received(:perform_later).with(saved, saved.material_file.blob.id).once
  end
end
