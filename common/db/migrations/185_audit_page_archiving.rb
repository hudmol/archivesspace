Sequel.migration do
  up do
    alter_table(:audit_page) do
      add_column(:first_id_written, Integer, default: 0, null: false)

      MediumBlobField :archive

      add_index([:page_event_type, :page_filter, :first_id_written, :last_id_written],
                name: :audit_page_archive_idx)
    end
  end
end
