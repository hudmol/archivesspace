Sequel.migration do
  no_audit_events_required!

  up do
    alter_table(:audit_page) do
      add_column(:bulk_object_repo_id, Integer, :unsigned => true, :null => true)
      add_column(:bulk_target_repo_id, Integer, :unsigned => true, :null => true)
    end
  end
end
