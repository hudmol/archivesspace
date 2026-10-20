Sequel.migration do
  no_audit_events_required!

  up do
    alter_table(:deleted_records) do
      add_column(:record_id, Integer)
      add_index(:record_id, :name => "deleted_records_record_id_idx")
    end

    self.transaction do
      min_id = self[:deleted_records].min(:id)
      max_id = self[:deleted_records].max(:id)

      if min_id && max_id
        batch_size = 200
        lower = min_id

        while lower <= max_id
          upper = lower + batch_size

          self[:deleted_records].where { (id >= lower) & (id < upper) }.each do |row|
            record_id = row.fetch(:uri).gsub(%r{.*/}, '').to_i
            self[:deleted_records].filter(:id => row[:id]).update(:record_id => record_id)
          end

          lower += batch_size
        end
      end
    end
  end

end
