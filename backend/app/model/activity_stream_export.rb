require 'csv'

class ActivityStreamExport < Sequel::Model(:audit_export)

  include ASModel
  corresponds_to JSONModel(:activity_stream_export)
  set_model_scope :global

  EXPORT_TYPES = [
    EXPORT_TYPE_USER = 'EXPORT_TYPE_USER',
    EXPORT_TYPE_COLLECTION = 'EXPORT_TYPE_COLLECTION',
    EXPORT_TYPE_REPOSITORY = 'EXPORT_TYPE_REPOSITORY',
    EXPORT_TYPE_DELETE_MERGE_TRANSFER = 'EXPORT_TYPE_DELETE_MERGE_TRANSFER',
  ]

  EXPORT_STATUS = [
    EXPORT_STATUS_QUEUED = 'EXPORT_STATUS_QUEUED',
    EXPORT_STATUS_RUNNING = 'EXPORT_STATUS_RUNNING',
    EXPORT_STATUS_COMPLETE = 'EXPORT_STATUS_COMPLETE',
    EXPORT_STATUS_ERRORED = 'EXPORT_STATUS_ERRORED',
  ]

  class FakeUser
    def id
      1
    end
  end

  def self.queue_with_criteria(type = EXPORT_TYPE_USER, criteria = {})
    unless EXPORT_TYPES.include?(type)
      raise "Invalid export type: #{type}"
    end

    export = self.new

    export.lock_version = 0
    export.criteria = criteria.to_json

    export.export_type = type
    export.status = EXPORT_STATUS_QUEUED

    export.created_by = RequestContext.get(:current_username) || 'admin'
    export.create_time = Time.now
    export.system_mtime = Time.now

    export.save

    # and instantiate the job runner to kick off the export
    job = Job.create_from_json(JSONModel(:job).from_hash({
            job_type: 'activity_stream_export_job',
            job: {
              'jsonmodel_type' => 'activity_stream_export_job',
            },
          }), user: FakeUser.new) # FIXME current_user

    export.job_id = job.id
    export.save

    export
  end

  def write_csv(file)
    criteria = ASUtils.json_parse(self.criteria)
    stream_stats = DB.open do |db|
      AuditPaginator.page_statistics(db, nil)
    end

    case self.export_type
    when EXPORT_TYPE_USER
      file << CSV.generate_line(['Username', 'URI', 'Repository Short Name', 'Change type', 'Change method', 'Date'])
    when EXPORT_TYPE_COLLECTION
      file << CSV.generate_line(['Resource URI', 'Username', 'Changed object URI', 'Change type', 'Change method', 'Date'])
    when EXPORT_TYPE_REPOSITORY
      file << CSV.generate_line(['Repository URI', 'Username', 'Changed object URI', 'Change type', 'Change method', 'Date'])
    when EXPORT_TYPE_DELETE_MERGE_TRANSFER
      file << CSV.generate_line(['Username', 'Changed object URI', 'Target URI', 'Change type', 'Change method', 'Date'])
    else
      raise "Invalid export type: #{type}"
    end

    page = 1
    while page <= stream_stats.last_page do
      # pp "** PROCESSING PAGE #{page} of #{stream_stats.last_page} **"
      AuditEvent.page(page, nil).fetch(:orderedItems).each do |event|
        event = deep_keys_as_strings(event)

        ASUtils.wrap(event.fetch('object')).each do |event_record|
          record_uri = event_record.fetch('id').sub(AppConfig[:backend_url], '/').sub('//', '/')
          record_type = event_record.fetch('type')

          next unless event_matches_criteria?(event, record_uri, record_type, criteria)


          case self.export_type
          when EXPORT_TYPE_USER
            file << CSV.generate_line([
              event.fetch('actor').fetch('name'),
              record_uri,
              repo_short_name_for_record(record_uri),
              event.fetch('type'),
              event.fetch('method_of_change'),
              event.fetch('endTime')
            ])
          when EXPORT_TYPE_COLLECTION
            file << CSV.generate_line([
              criteria.fetch('resource').fetch('ref'),
              event.fetch('actor').fetch('name'),
              record_uri,
              event.fetch('type'),
              event.fetch('method_of_change'),
              event.fetch('endTime')
            ])
          when EXPORT_TYPE_REPOSITORY
            file << CSV.generate_line([
              criteria.fetch('repository').fetch('ref'),
              event.fetch('actor').fetch('name'),
              record_uri,
              event.fetch('type'),
              event.fetch('method_of_change'),
              event.fetch('endTime')
            ])
          when EXPORT_TYPE_DELETE_MERGE_TRANSFER
            file << CSV.generate_line([
              event.fetch('actor').fetch('name'),
              record_uri,
              event.dig('target', 'id').to_s.sub(AppConfig[:backend_url], '/').sub('//', '/'),
              event.fetch('summary', event.fetch('type')).capitalize,
              event.fetch('method_of_change'),
              event.fetch('endTime')
            ])
          else
            raise "Invalid export type: #{self.export_type}"
          end
        end
      end

      page += 1
    end
  end

  def deep_keys_as_strings(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, nested), result|
        result[key.to_s] = deep_keys_as_strings(nested)
      end
    when Array
      value.map { |nested| deep_keys_as_strings(nested) }
    else
      value
    end
  end

  def event_matches_criteria?(event, record_uri, record_type, criteria)
    date_of_event_in_local_time = Time.parse(event.fetch('endTime')).getlocal.strftime('%Y-%m-%d')

    if criteria['from_date'] && date_of_event_in_local_time < criteria['from_date']
      return false
    end

    if criteria['to_date'] && date_of_event_in_local_time > criteria['to_date']
      return false
    end

    if criteria['activity_type'] && !criteria['activity_type'].empty? && !criteria['activity_type'].include?(event.fetch('type'))
      return false
    end

    if criteria['change_method'] && !criteria['change_method'].empty? && !criteria['change_method'].include?(event.fetch('method_of_change'))
      return false
    end

    if criteria['user'] && event.fetch('actor').fetch('name') != username_for_criteria(criteria['user']['ref'])
      return false
    end

    if criteria['object_type'] && !criteria['object_type'].empty? && !criteria['object_type'].include?(record_type)
      return false
    end

    if criteria['resource'] && !record_is_in_criteria_resource?(criteria, record_type, record_uri)
      return false
    end

    if criteria['repository'] && !event_associated_with_repository?(event, record_uri, criteria['repository']['ref'])
      return false
    end

    true
  end

  def username_for_criteria(user_ref)
    return @criteria_cache[user_ref] if @criteria_cache && @criteria_cache[user_ref]

    user_id = JSONModel(:user).id_for(user_ref)

    user = User.get_or_die(user_id)

    @criteria_cache ||= {}
    @criteria_cache[user_ref] = user.username

    user.username
  end

  def event_associated_with_repository?(event, record_uri, repository_uri)
    # did you happen to the repository?
    return true if record_uri == repository_uri

    # check if the record is in the repository
    return true if record_uri.start_with?(repository_uri + '/')

    # check if the record was transferred into the repository
    return true if event.fetch('target', {}).fetch('id', '').include?(repository_uri + '/')

    # if the record is from another repository, then it is not associated
    return false if record_uri.start_with?('/repositories/')

    # for global events, check if the actor has access to the repository in question
    username = event.fetch('actor').fetch('name')

    # populate a cache of all the admin users and the users and the repositories they have access to
    if !@criteria_repository_user_cache && !@criteria_admin_user_cache
      # all the admin users
      @criteria_admin_user_cache = Set.new

      # users and the repositories they have access to
      @criteria_repository_user_cache = {}

      DB.open do |db|
        db[:group]
          .join(:group_user, Sequel.qualify(:group_user, :group_id) => Sequel.qualify(:group, :id))
          .join(:user, Sequel.qualify(:group_user, :user_id) => Sequel.qualify(:user, :id))
          .filter(Sequel.qualify(:group, :group_code) => 'administrators')
          .select(
            Sequel.qualify(:user, :username))
          .each do |row|
          @criteria_admin_user_cache.add(row[:username])
        end

        db[:group]
          .join(:group_user, Sequel.qualify(:group_user, :group_id) => Sequel.qualify(:group, :id))
          .join(:user, Sequel.qualify(:group_user, :user_id) => Sequel.qualify(:user, :id))
          .select(
            Sequel.qualify(:group, :repo_id),
            Sequel.qualify(:user, :username))
          .each do |row|
          @criteria_repository_user_cache[row[:username]] ||= Set.new
          @criteria_repository_user_cache[row[:username]] << JSONModel(:repository).uri_for(row[:repo_id])
        end
      end
    end

    @criteria_admin_user_cache.include?(username) ||
      @criteria_repository_user_cache.fetch(username, Set.new).include?(repository_uri)
  end

  def self.sequel_to_jsonmodel(objs, opts = {})
    jsons = super
    jsons.zip(objs).each do |json, obj|
      json.criteria = ASUtils.json_parse(obj.criteria)
    end
    jsons
  end

  def running!
    self.status = EXPORT_STATUS_RUNNING
    self.save
  end

  def complete!(export_file_path)
    self.export_file_path = export_file_path
    self.status = EXPORT_STATUS_COMPLETE
    self.save
  end

  def errored!
    self.status = EXPORT_STATUS_ERRORED
    self.save
  end

  def record_is_in_criteria_resource?(criteria, record_type, record_uri)
    resource_uri = criteria.fetch('resource').fetch('ref')

    if resource_uri == record_uri
      return true
    end

    if record_type != 'archival_object'
      # FIXME are there other record types we can link to the resource?
      return false
    end

    unless @resource_object_ids_cache
      @resource_object_ids_cache = RoaringBitmap.new
      resource_id = JSONModel(:resource).id_for(resource_uri)
      ArchivalObject
        .filter(:root_record_id => resource_id)
        .select(:id)
        .each do |row|
        @resource_object_ids_cache.add(row[:id])
      end
    end

    archival_object_id = JSONModel(:archival_object).id_for(record_uri)

    @resource_object_ids_cache.include?(archival_object_id)
  end

  def repo_short_name_for_record(record_uri)
    parsed = JSONModel.parse_reference(record_uri)

    repository_uri =
      if parsed.fetch(:type) == 'repository'
        record_uri
      elsif parsed.fetch(:repository)
        parsed.fetch(:repository)
      else
        nil
      end

    return repository_uri if repository_uri.nil?
    return @criteria_cache.fetch(repository_uri) if @criteria_cache && @criteria_cache[repository_uri]

    repo_id = JSONModel(:repository).id_for(repository_uri)
    repo = Repository.get_or_die(repo_id)
    @criteria_cache[repository_uri] = repo.repo_code

    repo.repo_code
  end

  def self.validate_criteria!(export_type, criteria)
    unless EXPORT_TYPES.include?(export_type)
      raise "Invalid export type: #{export_type}"
    end

    unless criteria['from_date']
      raise "Missing from_date in criteria"
    end

    begin
      if criteria['from_date'] =~ /[1-2]\d{3}-[01]\d-[0-3]\d/
        Date.strptime(criteria['from_date'], '%Y-%m-%d')
      else
        raise ArgumentError.new("Invalid date")
      end
    rescue ArgumentError
      raise "Invalid from_date in criteria"
    end

    unless criteria['to_date']
      raise "Missing to_date in criteria"
    end

    begin
      if criteria['to_date'] =~ /[1-2]\d{3}-[01]\d-[0-3]\d/
        Date.strptime(criteria['to_date'], '%Y-%m-%d')
      else
        raise ArgumentError.new("Invalid date")
      end
    rescue ArgumentError
      raise "Invalid to_date in criteria"
    end

    case export_type
    when EXPORT_TYPE_USER
      unless criteria['user'] && criteria['user']['ref']
        raise "Missing user ref"
      end
    when EXPORT_TYPE_COLLECTION
      unless criteria['resource'] && criteria['resource']['ref']
        raise "Missing resource ref"
      end
    when EXPORT_TYPE_REPOSITORY
      unless criteria['repository'] && criteria['repository']['ref']
        raise "Missing repository ref"
      end
    when EXPORT_TYPE_DELETE_MERGE_TRANSFER
      unless criteria['object_type'] && !criteria['object_type'].empty?
        raise "Missing object type(s)"
      end

      criteria['object_type'].each do |object_type|
        unless AuditEvent.object_types.include?(object_type)
          raise "Invalid object type: #{object_type}"
        end
      end

      criteria['activity_type'] = [
        AuditEvent::ACTIVITY_TYPE_CODE_TABLE[AuditEvent::ACTIVITY_TYPE_DELETE],
        AuditEvent::ACTIVITY_TYPE_CODE_TABLE[AuditEvent::ACTIVITY_TYPE_MOVE],
      ]
    else
      raise "Invalid export type: #{export_type}"
    end
  end
end