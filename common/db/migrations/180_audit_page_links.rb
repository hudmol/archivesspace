Sequel.migration do
  up do
    alter_table(:audit_page) do
      add_column(:bulk_all_stream_page_number, Integer, :null => true)
    end

    pages = {}

    self[:audit_page]
      .filter(:page_event_type => 'bulk')
      .select(:id, :page_number, :page_filter, Sequel.as(Sequel.function(:sha1, :id_set), :sha1), :update_time)
      .each do |page|
      pages[page.fetch(:sha1)] ||= {}
      pages[page.fetch(:sha1)][page.fetch(:update_time).to_i] ||= {}
      pages[page.fetch(:sha1)][page.fetch(:update_time).to_i][page.fetch(:page_filter)] = {row_id: page.fetch(:id), page_number: page.fetch(:page_number)}
    end

    pages.values.each do |batches|
      batches.values.each do |pairs|
        raise "oops" unless pairs.length == 2

        all_stream_page = pairs.delete('_all')
        other_filter_page = pairs.values[0]

        self[:audit_page].filter(id: all_stream_page.fetch(:row_id)).update(bulk_all_stream_page_number: all_stream_page.fetch(:page_number))
        self[:audit_page].filter(id: other_filter_page.fetch(:row_id)).update(bulk_all_stream_page_number: all_stream_page.fetch(:page_number))
      end
    end

    if self[:audit_page].filter(:page_event_type => 'bulk').filter(:bulk_all_stream_page_number => nil).count > 0
      raise
    end

  end
end
