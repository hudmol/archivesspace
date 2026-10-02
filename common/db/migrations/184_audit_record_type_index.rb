Sequel.migration do
  no_audit_events_required!

  up do
    alter_table(:audit_record) do
      add_index([:type], :name => 'audit_record_type_idx')
    end
  end
end
