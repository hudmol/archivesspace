Sequel.migration do
  up do
    create_table(:audit_page) do
      primary_key :id
      Integer :page_number, null: false
      String :page_filter, size: 255, null: false
      String :page_event_type, size: 255, null: false
      DateTime :update_time
      Integer :is_page_complete, null: false
      Integer :last_id_written, null: false
      Integer :event_count, null: false
      File :id_set

      index [:page_filter, :page_number, :event_count], name: :audit_page_filter_idx
      index [:page_filter, :is_page_complete], name: :audit_page_complete_idx
    end

    create_table(:audit_page_lock) do
      primary_key :id
    end

    # Insert our lock row
    self[:audit_page_lock].insert
  end
end
