Sequel.migration do
  no_audit_events_required!

  up do
    alter_table(:audit_page) do
      add_column(:system_generated, Integer, :default => 0, :null => false)
    end
  end

end
