namespace :demo do
  desc "Create fictional samples in an explicitly isolated local test database"
  task seed: :environment do
    puts JSON.generate(Demo::Seed.new.call)
  end
end
