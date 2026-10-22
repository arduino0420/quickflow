require "rails_helper"
require "rake"

RSpec.describe "Operator teacher provisioning" do
  let(:school) { School.create!(school_code: "PROVISION") }
  let(:task) { Rake::Task["accounts:create_teacher"] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("accounts:create_teacher")
    task.reenable
    allow(STDIN).to receive(:tty?).and_return(true)
    allow(STDIN).to receive(:noecho).and_yield
    allow($stdout).to receive(:print)
    allow($stdout).to receive(:puts)
  end

  def inputs(user_id: "provisioned", password: "Matsue2026", confirmation: password)
    school
    allow(STDIN).to receive(:gets).and_return("y\n", "PROVISION\n", "#{user_id}\n", "#{password}\n", "#{confirmation}\n")
  end

  it "creates only a teacher in an existing verified school and hides passwords" do
    inputs
    original_schools = School.count
    original_students = Student.count
    expect { task.invoke }.to change(Teacher, :count).by(1)
    teacher = Teacher.find_by!(user_id: "provisioned")
    expect(teacher.school).to eq(school)
    expect(teacher.authenticate("Matsue2026")).to eq(teacher)
    expect(teacher.password_digest).not_to eq("Matsue2026")
    expect(STDIN).to have_received(:noecho).twice
    expect($stdout).not_to have_received(:puts).with(/Matsue2026/)
    expect($stdout).not_to have_received(:print).with(/Matsue2026/)
    expect(School.count).to eq(original_schools)
    expect(Student.count).to eq(original_students)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.post("/login", params: { session: { user_id: teacher.user_id, password: "Matsue2026" } })
    expect(session.response.status).to eq(303)
    expect(URI(session.response.location).path).to eq("/assignments")
    session.get("/assignments")
    expect(session.response.status).to eq(200)
  end

  [ { password: "", confirmation: "" }, { confirmation: "different" }, { password: "a" * 73 },
    { password: "short" }, { password: "password123456789" }, { user_id: "" } ].each do |change|
    it "rejects invalid teacher input #{change.keys.inspect}" do
      inputs(**change)
      expect { expect { task.invoke }.to raise_error(SystemExit) }.not_to change(Teacher, :count)
    end
  end

  it "rejects duplicate teacher user IDs" do
    inputs
    existing = Teacher.create!(school: school, user_id: "provisioned", password: "old-password")
    original = existing.attributes
    expect { expect { task.invoke }.to raise_error(SystemExit) }.not_to change(Teacher, :count)
    expect(existing.reload.attributes).to eq(original)
  end

  it "does not create a school from an unknown code" do
    allow(STDIN).to receive(:gets).and_return("y\n", "UNKNOWN\n")
    original_teachers = Teacher.count
    expect { expect { task.invoke }.to raise_error(SystemExit) }.not_to change(School, :count)
    expect(Teacher.count).to eq(original_teachers)
  end

  it "refuses provisioning without operator confirmation" do
    allow(STDIN).to receive(:gets).and_return("n\n")
    expect { expect { task.invoke }.to raise_error(SystemExit) }.not_to change(Teacher, :count)
  end

  it "refuses noninteractive execution" do
    allow(STDIN).to receive(:tty?).and_return(false)
    expect { expect { task.invoke }.to raise_error(SystemExit) }.not_to change(Teacher, :count)
    expect(STDIN).not_to have_received(:noecho)
  end
end
