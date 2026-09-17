class UserBasedAuditEventReport < AbstractReport
  register_report({
                    :params => [
                      ["from", Date, "The start of report range"],
                      ["to", Date, "The start of report range"],
                      ["user_agent_ref", 'User', "The user to report on"],
                    ],
                    :formats => ['csv'],
                    :suppress_csv_options => true,
                  })

  def initialize(params, job, db)
    super

    pp 'UserBasedAuditEventReport', params

    from = (params['from'] || raise('From date is required')) + 'T00:00:00'
    to = (params['to'] || raise('To date is required')) + 'T23:59:59'

    @from = DateTime.parse(from).to_time.strftime('%Y-%m-%d %H:%M:%S')
    @to = DateTime.parse(to).to_time.strftime('%Y-%m-%d %H:%M:%S')

    @user_ref = params['user_agent_ref'] || raise('User is required')
    @user_id = (db[:user]
                 .join(:agent_person, Sequel.qualify(:agent_person, :id) => Sequel.qualify(:user, :agent_record_id))
                 .filter(Sequel.qualify(:agent_person, :id) => JSONModel(:agent_person).id_for(@user_ref))
                 .select(Sequel.qualify(:user, :id))
                 .first || {})[:id] || raise('Valid user is required')

    @info[:scoped_by_date_range] = "#{@from} to #{@to}"
    @info[:scoped_by_user] = "User: #{@user_ref} (ID: #{@user_id})"
  end

  def override_generate?
    true
  end

  def handle_generate(file)
    CSV.open(file.path, 'wb') do |csv|
      csv << ['User', 'Event Type', 'Record Type', 'Record ID', 'Timestamp']

      # do the business
    end
  end
end
