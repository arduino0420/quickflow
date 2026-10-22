module Demo
  class RejectJobsAdapter
    def enqueue(_job)
      raise Profile::Unsafe, "Jobs forbidden in demo identity"
    end

    def enqueue_at(_job, _timestamp)
      raise Profile::Unsafe, "Jobs forbidden in demo identity"
    end
  end

  module ReadOnlyStorage
    %i[upload delete delete_prefixed compose update_metadata].each do |operation|
      define_method(operation) do |*args, **kwargs|
        raise Profile::Unsafe, "Storage writes forbidden in demo runtime" unless Profile.provisioning?
        super(*args, **kwargs)
      end
    end
  end
end
