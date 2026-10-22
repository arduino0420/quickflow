require_relative "../lib/demo/profile"
Demo::Profile.validate_boot!
Demo::Profile.validate_bind!
raise Demo::Profile::Unsafe, "Runtime identity required" unless Demo::Profile.identity? && !Demo::Profile.provisioning?
threads 1, 3
workers 0
bind ENV.fetch("QUICKFLOW_DEMO_BIND")
preload_app!
pidfile ENV.fetch("QUICKFLOW_DEMO_PIDFILE")
