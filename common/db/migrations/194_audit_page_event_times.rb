Sequel.migration do
  up do
    # FIXME REMOVE EVENTUALLY - this is required to clear old test data while in the QA acceptance phase.
    self.transaction do
      self[:audit_record].delete
      self[:audit_event].delete
      self[:audit_page].delete
      self[:audit_bulk_page_pending].delete
      self[:audit_enabled_tracking].delete
    end

    alter_table(:audit_page) do
      add_column(:earliest_event_timestamp, DateTime, null: false)
      add_column(:latest_event_timestamp, DateTime, null: false)
    end

    # We rely on this being there for the above changes.
    alter_table(:audit_bulk_page_pending) do
      set_column_not_null(:update_time)
    end

  end

end
