class DeleteMergeTransferAuditEventReport < AbstractReport
  register_report({
                    :params => [
                      ["from", Date, "The start of report range"],
                      ["to", Date, "The start of report range"],
                      ["object_type", 'StringList', "The object type to report on", AuditEvent.object_types],
                    ],
                    :formats => ['csv'],
                    :suppress_csv_options => true,
                  })

  def initialize(params, job, db)
    super

    pp 'DeleteMergeTransferAuditEventReport', params

    from = (params['from'] || raise('From date is required')) + 'T00:00:00'
    to = (params['to'] || raise('To date is required')) + 'T23:59:59'

    @from = DateTime.parse(from).to_time.strftime('%Y-%m-%d %H:%M:%S')
    @to = DateTime.parse(to).to_time.strftime('%Y-%m-%d %H:%M:%S')

    @object_type_code = AuditEvent.object_type_code_for(params['object_type']) || raise('Object type is required')

    @info[:scoped_by_date_range] = "#{@from} to #{@to}"
    @info[:scoped_by_object_type] = "Object type: #{@object_type} [#{@object_type_code}]"
  end

  def override_generate?
    true
  end

  def handle_generate(file)
    CSV.open(file.path, 'wb') do |csv|
      csv << ['Username', 'Changed object URI', 'Target URI', 'Change type', 'Change method', 'Date']

      # do the business
    end
  end
end
