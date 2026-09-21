class RepositoryAuditEventReport < AbstractReport
  register_report({
                    :params => [
                      ["from", Date, "The start of report range"],
                      ["to", Date, "The start of report range"],
                      ["repository_ref", 'Repository', "The Repository to report on"],
                    ],
                    :formats => ['csv'],
                    :suppress_csv_options => true,
                  })

  def initialize(params, job, db)
    super

    pp 'RepositoryAuditEventReport', params

    from = (params['from'] || raise('From date is required')) + 'T00:00:00'
    to = (params['to'] || raise('To date is required')) + 'T23:59:59'

    @from = DateTime.parse(from).to_time.strftime('%Y-%m-%d %H:%M:%S')
    @to = DateTime.parse(to).to_time.strftime('%Y-%m-%d %H:%M:%S')

    @repository_ref = params['repository_ref'] || raise('Repository is required')

    @info[:scoped_by_date_range] = "#{@from} to #{@to}"
    @info[:scoped_by_repository] = "Repository: #{@repository_ref}"
  end

  def override_generate?
    true
  end

  def handle_generate(file)
    CSV.open(file.path, 'wb') do |csv|
      csv << ['Repository URI', 'Username', 'Changed object URI', 'Change type', 'Change method', 'Date']

      # do the business
    end
  end
end
