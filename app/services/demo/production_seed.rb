module Demo
  class ProductionSeed < Seed
    def verify_runtime_manifest!
      @root = TargetVerifier.new.verify_endpoint!.fetch(:root)
      verify_inventory!
      refuse!("Missing production manifest") unless @root.join(".seed-manifest.json").file?
      File.open(@root.join(".seed.lock"), File::RDONLY) do |lock|
        refuse!("Provisioning in progress") unless lock.flock(File::LOCK_SH | File::LOCK_NB)
        expected = JSON.parse(@root.join(".seed-manifest.json").read)
        actual = snapshot
        [ expected, actual ].each { |value| value.fetch("tables").delete(AuthenticationAttemptBucket.table_name) }
        refuse!("Production demo manifest differs") unless actual == expected
      end
      true
    end

    private

    def guard!
      raise Profile::Unsafe, "Explicit provisioning task required" unless Profile.provisioning?
      @root = TargetVerifier.new.verify_endpoint!(provisioning: true).fetch(:root)
    end

    def storage_service_name
      "production_demo"
    end

    def snapshot
      result = super
      result["contract"] = { "version" => 1, "profile" => "production-demo",
        "target" => Profile.settings.except("version") }
      result["metadata"] = %w[schema_migrations ar_internal_metadata].to_h do |table|
        order = table == "schema_migrations" ? "version" : "key"
        data = connection.select_all("SELECT * FROM #{connection.quote_table_name(table)} ORDER BY #{connection.quote_column_name(order)}").to_a
        canonical = data.map { |row| row.transform_values { |value| value.respond_to?(:usec) ? value.iso8601(6) : value } }
        [ table, Digest::SHA256.hexdigest(JSON.generate(canonical)) ]
      end
      result
    end
  end
end
