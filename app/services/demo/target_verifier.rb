module Demo
  class TargetVerifier
    METADATA = %w[schema_migrations ar_internal_metadata].freeze

    def initialize
      @target = Profile.settings
      @connection = ApplicationRecord.connection
    end

    def verify_endpoint!(provisioning: false)
      Profile.validate_boot!
      raise Profile::Unsafe, "Production demo identity required" unless Profile.identity? && Rails.env.production?
      role = @target.fetch(provisioning ? "provision_role" : "runtime_role")
      actual = @connection.select_one(<<~SQL)
        SELECT current_database() AS database, host(inet_server_addr()) AS host,
          inet_server_port()::text AS port, current_user AS role, session_user AS session_role,
          shobj_description(oid, 'pg_database') AS marker
        FROM pg_database WHERE datname=current_database()
      SQL
      expected = { "database" => @target["database"], "host" => @target["host"], "port" => @target["port"].to_s,
        "role" => role, "session_role" => role, "marker" => "quickflow-production-demo:#{@target['isolation_id']}" }
      refuse!("Observed demo endpoint differs") unless actual == expected
      configs = ApplicationRecord.configurations.configs_for(env_name: "production")
      refuse!("Secondary configurations forbidden") unless configs.map(&:name) == [ "primary" ]
      config = ApplicationRecord.connection_db_config.configuration_hash
      refuse!("Rails connection differs") unless config[:database] == actual["database"] && config[:host] == actual["host"] && config[:port].to_s == actual["port"] && config[:username] == role
      refuse!("Search path differs") unless @connection.select_value("SHOW search_path") == "public"
      root = Pathname.new(@target.fetch("storage_root"))
      refuse!("Storage missing or redirected") unless root.directory? && root.realpath == root
      service = ActiveStorage::Blob.services.fetch("production_demo")
      refuse!("Dedicated Disk storage required") unless service.instance_of?(ActiveStorage::Service::DiskService) && Pathname.new(service.root).expand_path == root
      refuse!("Storage marker differs") unless root.join(".demo-isolation").file? && root.join(".demo-isolation").read == @target["isolation_id"]
      refuse!("Storage symbolic link forbidden") if root.glob("**/*", File::FNM_DOTMATCH).any?(&:symlink?)
      service.singleton_class.prepend(ReadOnlyStorage) unless service.singleton_class.ancestors.include?(ReadOnlyStorage)
      { root: root, service: service }
    end

    def verify_runtime!
      # Repeated checks must observe current grants/data rather than an earlier
      # successful verification cached by this executor (including Rails runner).
      ApplicationRecord.uncached do
        verify_endpoint!
        verify_inventory!
        verify_runtime_grants!
        ProductionSeed.new.verify_runtime_manifest!
      end
      true
    rescue Seed::UnsafeTarget, JSON::ParserError, KeyError, IOError, SystemCallError, ActiveRecord::ActiveRecordError => error
      raise Profile::Unsafe, "Production demo verification failed (#{error.class})"
    end

    def verify_provisioning_cluster!
      verify_endpoint!(provisioning: true)
      actual = @connection.select_rows("SELECT current_setting('data_directory'), (SELECT system_identifier::text FROM pg_control_system())").first
      refuse!("Provisioning cluster identity differs") unless actual == @target.values_at("data_directory", "system_identifier")
      true
    end

    def verify_inventory!
      expected = Seed::TABLE_MODELS.map(&:table_name) + METADATA
      rows = @connection.select_rows(<<~SQL)
        SELECT n.nspname,c.relname,c.relkind,c.relrowsecurity,c.relforcerowsecurity
        FROM pg_namespace n LEFT JOIN pg_class c ON c.relnamespace=n.oid AND c.relkind IN ('r','p','f','m','v')
        WHERE n.nspname<>'information_schema' AND (n.nspname !~ '^pg_' OR (n.nspname ~ '^pg_temp_[0-9]+$' AND c.oid IS NOT NULL))
      SQL
      refuse!("Unknown demo schema/table or row policy") unless rows.all? { |schema, table, kind, rls, forced| schema == "public" && expected.include?(table) && kind == "r" && !rls && !forced } && rows.map { |row| row[1] }.sort == expected.sort
      sequences = @connection.select_values("SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='S'")
      expected_sequences = Seed::TABLE_MODELS.reject { |model| model == AuthenticationAttemptBucket }.map { |model| "#{model.table_name}_id_seq" }
      refuse!("Unknown or missing demo sequence") unless sequences.sort == expected_sequences.sort
      unsafe = @connection.select_value(<<~SQL)
        SELECT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname !~ '^pg_' AND n.nspname<>'information_schema')
          OR EXISTS(SELECT 1 FROM pg_extension WHERE extname<>'plpgsql')
          OR EXISTS(SELECT 1 FROM pg_foreign_server)
      SQL
      refuse!("Unapproved functions/extensions/servers") if unsafe
      true
    end

    def verify_runtime_grants!
      role = @connection.quote(@target.fetch("runtime_role"))
      info = @connection.select_one("SELECT oid,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolreplication,rolbypassrls,rolcanlogin FROM pg_roles WHERE rolname=#{role}")
      refuse!("Unsafe runtime role flags") unless info && info["rolcanlogin"] && %w[rolsuper rolinherit rolcreaterole rolcreatedb rolreplication rolbypassrls].none? { |key| info[key] }
      oid = @connection.quote(Integer(info.fetch("oid")))
      memberships = @connection.select_value("SELECT EXISTS(SELECT 1 FROM pg_roles WHERE oid<>#{oid} AND pg_has_role(#{oid},oid,'MEMBER'))")
      refuse!("Runtime role membership forbidden") if memberships
      db = @connection.quote(@target.fetch("database"))
      access = @connection.select_rows("SELECT has_database_privilege(#{role},#{db},'CONNECT'),has_database_privilege(#{role},#{db},'CREATE'),has_database_privilege(#{role},#{db},'TEMP')").first
      refuse!("Unsafe database access") unless access == [ true, false, false ]
      owns = @connection.select_value(<<~SQL)
        SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname=#{db} AND datdba=#{oid})
          OR EXISTS(SELECT 1 FROM pg_namespace WHERE nspowner=#{oid})
          OR EXISTS(SELECT 1 FROM pg_class WHERE relowner=#{oid})
          OR EXISTS(SELECT 1 FROM pg_proc WHERE proowner=#{oid})
          OR EXISTS(SELECT 1 FROM pg_type WHERE typowner=#{oid})
      SQL
      refuse!("Runtime ownership forbidden") if owns
      schemas = @connection.select_rows("SELECT nspname,has_schema_privilege(#{role},oid,'CREATE'),has_schema_privilege(#{role},oid,'USAGE') FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname<>'information_schema'")
      refuse!("Unsafe schema access") unless schemas == [ [ "public", false, true ] ]
      delegated = @connection.select_value(<<~SQL)
        SELECT EXISTS(SELECT 1 FROM pg_database d CROSS JOIN LATERAL aclexplode(d.datacl) a
          WHERE d.datname=#{db} AND a.grantee=#{oid} AND a.is_grantable)
          OR EXISTS(SELECT 1 FROM pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) a
            WHERE a.grantee=#{oid} AND a.is_grantable)
          OR EXISTS(SELECT 1 FROM pg_attribute c CROSS JOIN LATERAL aclexplode(c.attacl) a
            WHERE a.grantee=#{oid} AND a.is_grantable)
      SQL
      refuse!("Database/schema/column grant option forbidden") if delegated
      expected = Seed::TABLE_MODELS.map(&:table_name) + METADATA
      expected.each do |table|
        name = @connection.quote("public.#{table}")
        actual = @connection.select_rows(<<~SQL).first
          SELECT has_table_privilege(#{role},#{name},'SELECT'),
            has_table_privilege(#{role},#{name},'INSERT'),has_table_privilege(#{role},#{name},'UPDATE'),
            has_table_privilege(#{role},#{name},'DELETE'),has_table_privilege(#{role},#{name},'TRUNCATE'),
            has_table_privilege(#{role},#{name},'REFERENCES'),has_table_privilege(#{role},#{name},'TRIGGER'),
            has_table_privilege(#{role},#{name},'MAINTAIN'),has_any_column_privilege(#{role},#{name},'INSERT'),
            has_any_column_privilege(#{role},#{name},'UPDATE'),has_any_column_privilege(#{role},#{name},'REFERENCES')
        SQL
        allowed = table == AuthenticationAttemptBucket.table_name ? [ true, true, true, true, false, false, false, false, true, true, false ] : [ true ] + [ false ] * 10
        refuse!("Unexpected effective table/column privileges: #{table}") unless actual == allowed
        # Grant options would allow this credential to delegate access.
        grantable = @connection.select_value("SELECT EXISTS(SELECT 1 FROM aclexplode((SELECT relacl FROM pg_class WHERE oid=#{name}::regclass)) WHERE grantee=#{oid} AND is_grantable)")
        refuse!("Grant option forbidden") if grantable
      end
      sequences = @connection.select_value("SELECT EXISTS(SELECT 1 FROM pg_class WHERE relkind='S' AND (has_sequence_privilege(#{role},oid,'USAGE') OR has_sequence_privilege(#{role},oid,'SELECT') OR has_sequence_privilege(#{role},oid,'UPDATE')))")
      refuse!("Sequence access forbidden") if sequences
      true
    end

    private

    def refuse!(message)
      raise Profile::Unsafe, message
    end
  end
end
