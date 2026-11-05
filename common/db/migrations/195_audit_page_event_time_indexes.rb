Sequel.migration do
  up do
    alter_table(:audit_page) do
      add_index([:earliest_event_timestamp, :latest_event_timestamp, :page_filter], :name => 'audit_page_dates_idx')
    end
  end
end
