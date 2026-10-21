Sequel.migration do
  up do
    alter_table(:audit_event) do
      drop_column(:uuid)
    end
  end
end
