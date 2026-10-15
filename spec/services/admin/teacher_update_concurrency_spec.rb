require "rails_helper"
require "timeout"

RSpec.describe "Admin teacher editing concurrency" do
  self.use_transactional_tests = false

  before do
    @school = School.create!(school_code: "EDITCONCURRENT")
    @admin = Admin.create!(school: @school, user_id: "edit-concurrent-admin", password: "synthetic-password")
    @teacher = Teacher.create!(school: @school, user_id: "edit-concurrent-teacher", password: "synthetic-password")
    @threads = []
  end

  after do
    @threads.each { |thread| thread.join(10) }
    raise "Live worker prevents safe cleanup" if @threads.any?(&:alive?)

    TeacherClassroom.where(classroom_id: @school.classrooms.select(:id)).delete_all
    @school.classrooms.destroy_all
    @school.teachers.destroy_all
    @admin.destroy!
    @school.destroy!
  end

  def run_updates(requests)
    ready = Queue.new
    release = Queue.new
    requests.each do |teacher, token, codes|
      @threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET lock_timeout = '8s'")
          begin
            editor = Admin::TeacherUpdate.new(admin: Admin.find(@admin.id), teacher_id: teacher.id)
            ready << true
            Timeout.timeout(5) { release.pop }
            editor.call(attributes: {}, classroom_codes: codes, edit_token: token)
          ensure
            connection.execute("SET lock_timeout = DEFAULT")
          end
        end
      end
    end
    Timeout.timeout(5) { requests.size.times { ready.pop } }
    requests.size.times { release << true }
    @threads.map do |thread|
      raise "Update worker timed out" unless thread.join(10)

      thread.value
    end
  end

  it "accepts exactly one concurrent update of the same teacher and rejects the stale form" do
    token = Admin::TeacherUpdate.new(admin: @admin, teacher_id: @teacher.id).prepare.edit_token
    results = run_updates([ [ @teacher, token, [ "1-1" ] ], [ @teacher, token, [ "2-2" ] ] ])
    expect(results).to contain_exactly(true, false)
    expected = results.first ? [ 1, 1 ] : [ 2, 2 ]
    expect(@teacher.reload.classrooms.pluck(:grade, :class_number)).to eq([ expected ])
    expect(@school.classrooms.count).to eq(1)
    expect(TeacherClassroom.where(teacher: @teacher).count).to eq(1)
  end

  it "allows concurrent edits of different teachers to share a single newly created classroom" do
    other = Teacher.create!(school: @school, user_id: "edit-other-teacher", password: "synthetic-password")
    requests = [ @teacher, other ].map do |teacher|
      token = Admin::TeacherUpdate.new(admin: @admin, teacher_id: teacher.id).prepare.edit_token
      [ teacher, token, [ "3-10" ] ]
    end
    expect(run_updates(requests)).to eq([ true, true ])
    expect(@school.classrooms.count).to eq(1)
    expect(@school.classrooms.sole.teachers).to contain_exactly(@teacher, other)
  end
end
