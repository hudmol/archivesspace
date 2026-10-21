Sequel.migration do
  no_audit_events_required!

  up do
    # FIXME REMOVE EVENTUALLY - this is required to clear old test data while in the QA acceptance phase.
    self.transaction do
      self[:audit_record].delete
      self[:audit_event].delete
      self[:audit_page].delete
      self[:audit_enabled_tracking].delete
    end
  end

end
