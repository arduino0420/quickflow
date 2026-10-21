require "rails_helper"
require "timeout"

RSpec.describe "Admin teacher registration concurrency" do
  self.use_transactional_tests = false

  before do
    @school = School.create!(school_code: "REGCONCURRENT")
    @admin = Admin.create!(school: @school, user_id: "concurrent-admin", password: "synthetic-password")
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

  def register_concurrently(ids)
    ready = Queue.new
    release = Queue.new
    ids.each do |id|
      @threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET lock_timeout = '8s'")
          begin
            registration = Admin::TeacherRegistration.new(admin: Admin.find(@admin.id))
            ready << true
            Timeout.timeout(5) { release.pop }
            registration.call(attributes: { user_id: id, password: "Long River 8 Beacon 42", password_confirmation: "Long River 8 Beacon 42" },
              classroom_codes: [ "1-1" ])
          ensure
            connection.execute("SET lock_timeout = DEFAULT")
          end
        end
      end
    end
    Timeout.timeout(5) { ids.size.times { ready.pop } }
    ids.size.times { release << true }
    @threads.map do |thread|
      raise "Registration worker timed out" unless thread.join(10)

      thread.value
    end
  end

  it "creates one shared classroom for two simultaneous teacher registrations" do
    expect(register_concurrently([ "concurrent-one", "concurrent-two" ])).to eq([ true, true ])
    expect(@school.teachers.count).to eq(2)
    expect(@school.classrooms.count).to eq(1)
    expect(@school.classrooms.sole.teachers.count).to eq(2)
    expect(TeacherClassroom.where(classroom: @school.classrooms).count).to eq(2)
  end

  it "rejects one simultaneous duplicate ID without partial records" do
    expect(register_concurrently([ "concurrent-same", "concurrent-same" ])).to contain_exactly(true, false)
    expect(@school.teachers.count).to eq(1)
    expect(@school.classrooms.count).to eq(1)
    expect(TeacherClassroom.where(classroom: @school.classrooms).count).to eq(1)
  end
end
