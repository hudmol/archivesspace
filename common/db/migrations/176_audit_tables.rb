Sequel.migration do
  up do
    create_table(:audit_event) do
      primary_key :id
      String :uuid, :null => false
      DateTime :timestamp, :null => false
      column :activity_type, :tinyint, :unsigned => true, :null => false
      column :change_method, :tinyint, :unsigned => true, :null => false
      String :actor_name, :null => false
      column :actor_type, :tinyint, :unsigned => true, :null => false
    end

    create_table(:audit_record) do
      primary_key :id
      Integer :audit_event_id, :null => false
      String :uri, :null => false
      String :type, :null => false
      column :role, :tinyint, :unsigned => true, :null => false
    end

    alter_table(:audit_record) do
      add_foreign_key([:audit_event_id], :audit_event, :key => :id)
    end

  end
end
