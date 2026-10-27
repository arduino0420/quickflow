# Fictional samples are opt-in. Demo::Seed rejects unmarked databases,
# non-test environments, and non-isolated storage. Ordinary db:seed stays inert.
Demo::Seed.new.call if ENV["QUICKFLOW_DEMO_SEED"] == "true"
