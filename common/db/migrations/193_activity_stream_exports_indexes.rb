Sequel.migration do
  up do
    alter_table(:audit_export) do
      add_index([:status], :name => 'audit_export_status_idx')
    end
  end
end
