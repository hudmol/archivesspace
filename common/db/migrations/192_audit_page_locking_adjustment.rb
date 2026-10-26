Sequel.migration do
  up do
    alter_table(:audit_page_lock) do
      add_column(:lock_holder, String, null: true)
      add_column(:lock_expire_time, DateTime, null: true)
    end
  end

end
