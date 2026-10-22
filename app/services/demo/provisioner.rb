module Demo
  class Provisioner
    def call
      raise Profile::Unsafe, "Explicit provisioning task required" unless Profile.provisioning?
      verifier = TargetVerifier.new
      root = verifier.verify_endpoint!(provisioning: true).fetch(:root)
      verifier.verify_provisioning_cluster!
      if root.join(".seed-manifest.json").exist?
        verifier.verify_inventory!
        verifier.verify_runtime_grants!
        return ProductionSeed.new.call
      end
      connection = ApplicationRecord.connection
      inventory = connection.select_rows("SELECT n.nspname,c.relname FROM pg_namespace n LEFT JOIN pg_class c ON c.relnamespace=n.oid AND c.relkind IN ('r','p','f','m','v') WHERE n.nspname !~ '^pg_' AND n.nspname<>'information_schema'")
      raise Profile::Unsafe, "Provisioning requires a new empty database" unless inventory == [ [ "public", nil ] ]
      raise Profile::Unsafe, "Provisioning requires empty dedicated storage" unless Dir.children(root) == [ ".demo-isolation" ]
      Rake::Task["db:migrate"].invoke
      verifier.verify_inventory!
      result = ProductionSeed.new.call
      seal!(connection)
      verifier.verify_runtime_grants!
      result
    end

    private

    def seal!(connection)
      target = Profile.settings
      runtime = connection.quote_column_name(target.fetch("runtime_role"))
      database = connection.quote_column_name(target.fetch("database"))
      connection.execute("REVOKE ALL ON DATABASE #{database} FROM PUBLIC")
      connection.execute("REVOKE ALL ON SCHEMA public FROM PUBLIC")
      connection.execute("REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, #{runtime}")
      connection.execute("REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, #{runtime}")
      connection.execute("GRANT CONNECT ON DATABASE #{database} TO #{runtime}")
      connection.execute("GRANT USAGE ON SCHEMA public TO #{runtime}")
      tables = (Seed::TABLE_MODELS.map(&:table_name) + TargetVerifier::METADATA).map { |name| connection.quote_table_name(name) }
      connection.execute("GRANT SELECT ON #{tables.join(', ')} TO #{runtime}")
      connection.execute("GRANT INSERT, UPDATE, DELETE ON authentication_attempt_buckets TO #{runtime}")
    end
  end
end
