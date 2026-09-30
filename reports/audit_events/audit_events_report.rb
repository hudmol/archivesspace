class AuditEventsReport < AbstractReport

  def self.register_report(report_info)
    report_info[:permissions] = ['administer_system']

    super(report_info)
  end

  def repo_id
    1 # Global repository
  end
end
