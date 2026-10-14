# Protect after-commit PDF uploads as well as the database transaction.
class AssignmentLifecycleLock
  def self.synchronize(assignment_id)
    with_lock_scope do |acquire|
      acquire.call(assignment_id)
      yield
    end
  end

  # Creation acquires after INSERT (the ID is not yet visible to other sessions),
  # and retains the lock through commit callbacks. Existing records acquire first.
  def self.with_lock_scope
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      expression = nil
      acquire = lambda do |assignment_id|
        raise "Lifecycle lock already acquired" if expression

        key = connection.quote("quickflow-assignment-lifecycle:#{Integer(assignment_id)}")
        candidate = "hashtextextended(#{key}, 0)"
        connection.execute("SELECT pg_advisory_lock(#{candidate})")
        expression = candidate
      end
      begin
        yield acquire
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{expression})") if expression
      end
    end
  end
end
