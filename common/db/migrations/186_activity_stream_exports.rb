Sequel.migration do
  no_audit_events_required!

  up do
    create_table(:audit_export) do
      primary_key :id

      Integer :lock_version, null: false, default: 0

      String :export_type, null: false
      String :status, null: false
      String :criteria, null: false, text: true

      Integer :job_id
      String :export_file_path

      String :created_by
      DateTime :create_time, :null => false
      String :last_modified_by
      DateTime :user_mtime, :null => false
      DateTime :system_mtime, :null => false
    end

    alter_table(:audit_export) do
      add_foreign_key([:job_id], :job, :key => :id)
    end

    # create_table(:audit_export_criteria) do
    #   primary_key :id
    #
    #   Integer :audit_export_id, :null => false
    #
    #   String :criteria_type, null: false
    #   String :criteria_value, null: false
    # end
    #
    # alter_table(:audit_export_criteria) do
    #   add_foreign_key([:audit_export_id], :audit_export, :key => :id)
    # end
  end
end
