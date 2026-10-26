Sequel.migration do
  up do
    alter_table(:audit_event) do
      add_column(:sequence, Integer, null: true, default: nil)
      add_index(:sequence, name: "audit_event_sequence_idx", unique: true)
    end

    alter_table(:audit_page) do
      add_column(:last_sequence_written, Integer, null: false)
      add_index(:last_sequence_written, name: "audit_page_last_seq_idx")

      rename_column(:first_id_written, :min_id_written)
      rename_column(:last_id_written, :max_id_written)
    end

    self.transaction do
      # Offset sequence numbers so they never coincide with event IDs.  Any code
      # that confuses the two will then fail loudly.  This is really just for
      # developers, since nobody else will have data.  Maybe we nuke this when
      # merging!.
      base = (self[:audit_event].max(:id) || 0) + 1
      self[:audit_event].update(:sequence => Sequel.lit("id + #{base}"))

      # Move each page's cursor into sequence space too, so the paginator
      # carries on where it left off instead of re-reading every event.
      # Bulk pages keep their -1 placeholder.
      self[:audit_page]
        .filter(:page_event_type => ['audit', 'archived'])
        .update(:last_sequence_written => Sequel.lit("max_id_written + #{base}"))
    end
  end

end
