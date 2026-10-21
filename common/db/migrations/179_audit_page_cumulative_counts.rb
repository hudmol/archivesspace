Sequel.migration do
  up do
    alter_table(:audit_page) do
      add_column(:cumulative_prior_event_count, Integer, :unsigned => true, :null => true)
    end

    page_filters = self[:audit_page].distinct.select_map(:page_filter)

    self.transaction do
      page_filters.each do |filter|
        cumulative_count = 0
        self[:audit_page].filter(page_filter: filter).select(:id, :event_count).order(Sequel.asc(:page_number)).each do |row|
          self[:audit_page].filter(id: row.fetch(:id)).update(cumulative_prior_event_count: cumulative_count)
          cumulative_count += row.fetch(:event_count)
        end
      end
    end

    alter_table(:audit_page) do
      set_column_not_null(:cumulative_prior_event_count)
      add_index(:cumulative_prior_event_count)
    end

  end
end
