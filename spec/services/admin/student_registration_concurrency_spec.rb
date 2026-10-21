require "rails_helper"
require "timeout"

RSpec.describe "Admin student registration concurrency" do
  self.use_transactional_tests = false

  before do
    @school = School.create!(school_code: "PUPILCONCURRENT")
    @admin = Admin.create!(school: @school, user_id: "pupil-concurrent-admin", password: "synthetic-password")
    @threads = []
  end

  after do
    @threads.each { |thread| thread.join(10) }
    raise "Live worker prevents safe cleanup" if @threads.any?(&:alive?)

    TeacherClassroom.where(classroom_id: @school.classrooms.select(:id)).delete_all
    Student.where(classroom_id: @school.classrooms.select(:id)).delete_all
    @school.classrooms.destroy_all
    @school.teachers.destroy_all
    @admin.destroy!
    @school.destroy!
  end

  def register_concurrently(numbers)
    ready = Queue.new
    release = Queue.new
    numbers.each do |number|
      @threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET lock_timeout = '8s'")
          begin
            registration = Admin::StudentRegistration.new(admin: Admin.find(@admin.id))
            ready << true
            Timeout.timeout(5) { release.pop }
            registration.call(attributes: { grade: "1", class_number: "1", attendance_number: number,
              password: "739162840517294", password_confirmation: "739162840517294" })
          ensure
            connection.execute("SET lock_timeout = DEFAULT")
          end
        end
      end
    end
    Timeout.timeout(5) { numbers.size.times { ready.pop } }
    numbers.size.times { release << true }
    @threads.map do |thread|
      raise "Registration worker timed out" unless thread.join(10)

      thread.value
    end
  end

  it "creates a single classroom for two concurrent distinct students" do
    expect(register_concurrently([ "1", "2" ])).to eq([ true, true ])
    expect(@school.classrooms.count).to eq(1)
    expect(@school.classrooms.sole.students.pluck(:attendance_number)).to match_array([ 1, 2 ])
    expect(@school.teachers.count).to eq(0)
    expect(TeacherClassroom.where(classroom: @school.classrooms).count).to eq(0)
  end

  it "accepts exactly one concurrent duplicate student without partial records" do
    expect(register_concurrently([ "1", "1" ])).to contain_exactly(true, false)
    expect(@school.classrooms.count).to eq(1)
    expect(@school.classrooms.sole.students.count).to eq(1)
  end
end
