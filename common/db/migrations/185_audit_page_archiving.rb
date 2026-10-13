Sequel.migration do
  no_audit_events_required!

  up do
    alter_table(:audit_page) do
      add_column(:first_id_written, Integer, default: 0, null: false)
      add_column(:archive, File)
    end
  end
end
