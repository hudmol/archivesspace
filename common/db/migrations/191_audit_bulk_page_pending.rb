Sequel.migration do
  up do
    # Bulk event pages written by request threads, waiting for the
    # AuditPaginator thread to insert them into the activity stream.
    create_table(:audit_bulk_page_pending) do
      primary_key :id
      String :page_filter, size: 255, null: false
      DateTime :update_time
      Integer :min_id_written, null: false
      Integer :max_id_written, null: false
      Integer :event_count, null: false
      File :id_set

      column :bulk_record_type, :tinyint, :unsigned => true, :null => false
      column :bulk_activity_type, :tinyint, :unsigned => true, :null => false
      column :bulk_change_method, :tinyint, :unsigned => true, :null => false
      String :bulk_actor_name, :null => false
      column :bulk_actor_type, :tinyint, :unsigned => true, :null => false
      Integer :bulk_object_repo_id, :unsigned => true, :null => true
      Integer :bulk_target_repo_id, :unsigned => true, :null => true
      Integer :system_generated, :default => 0, :null => false
    end
  end

end
