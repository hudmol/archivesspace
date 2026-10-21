Sequel.migration do
  up do
    alter_table(:audit_page) do
      add_column(:bulk_record_type, :tinyint, :unsigned => true, :null => false)
      add_column(:bulk_activity_type, :tinyint, :unsigned => true, :null => false)
      add_column(:bulk_change_method, :tinyint, :unsigned => true, :null => false)
      add_column(:bulk_actor_name, String, :null => false)
      add_column(:bulk_actor_type, :tinyint, :unsigned => true, :null => false)

      add_unique_constraint([:page_filter, :page_number])
    end
  end
end
