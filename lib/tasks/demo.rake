namespace :demo do
  desc "Create fictional samples in an explicitly isolated local test database"
  task seed: :environment do
    puts JSON.generate(Demo::Seed.new.call)
  end
end

namespace :demo do
  desc "Provision a new explicitly declared production-mode synthetic demo"
  task provision: :environment do
    puts JSON.generate(Demo::Provisioner.new.call)
  end
end
