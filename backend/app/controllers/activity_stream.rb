class ArchivesSpaceService < Sinatra::Base

  Endpoint.get('/activity-stream/object_types')
    .description("Get a list of supported object types")
    .permissions([])
    .params()
    .returns([200, "a list of supported object types"]) \
  do
    json_response(AuditEvent.all_activity_streams)
  end

  Endpoint.get('/activity-stream')
    .description("Get an OrderedCollection of events for all object types")
    .permissions([])
    .params()
    .returns([200, "an OrderedCollection"]) \
  do
    activity_json_response(AuditEvent.activity_stream)
  end

  Endpoint.get('/activity-stream/page/:page')
    .description("Get a page of the activity stream")
    .permissions([])
    .params(["page", Integer, "The page to get"])
    .returns([200, "an OrderedCollectionPage"],
             [404, "page not available"]) \
  do
    result = AuditEvent.page(params[:page])

    if result
      activity_json_response(result)
    else
      raise NotFoundException.new("page not available")
    end
  end

  Endpoint.get('/activity-stream/event/:id')
    .description("Get an audit event by id")
    .permissions([])
    .params(["id", String, "The ID of the event to get"])
    .returns([200, "an audit event"],
             [404, "event not available"]) \
  do
    result = AuditEvent.by_id(params[:id])

    if result
      activity_json_response(result)
    else
      raise NotFoundException.new("event not available")
    end
  end

  Endpoint.get('/activity-stream/:object_type')
    .description("Get an OrderedCollection of events for object type")
    .permissions([])
    .params(["object_type", String, "The type of object to events for"])
    .returns([200, "an OrderedCollection"],
             [404, "unknown object type"]) \
  do
    if AuditEvent.object_types.include?(params[:object_type])
      activity_json_response(AuditEvent.activity_stream(params[:object_type]))
    else
      raise NotFoundException.new("unknown object type")
    end
  end

  Endpoint.get('/activity-stream/:object_type/page/:page')
    .description("Get a page of the activity stream for object type")
    .permissions([])
    .params(["object_type", String, "The type of object to events for"],
            ["page", Integer, "The page to get"])
    .returns([200, "an OrderedCollectionPage"],
             [404, "page not available"]) \
  do
    result = AuditEvent.page(params[:page], params[:object_type])

    if result
      activity_json_response(result)
    else
      raise NotFoundException.new("page not available")
    end
  end

  def activity_json_response(obj, status = 200)
    [status, {"Content-Type" => "application/activity+json"}, [obj.to_json(:mode => :trusted, :max_nesting => false) + "\n"]]
  end

  Endpoint.get('/activity-stream-export')
    .description("List all activity stream export jobs")
    .permissions([]) # FIXME add read permission
    .paginated(true)
    .returns([200, "List of export jobs"]) \
  do
    handle_listing(ActivityStreamExport, params, {}, Sequel.desc(:create_time))
  end

  Endpoint.post('/repositories/:repo_id/activity-stream-export/create')
    .description("Create a new activity stream export job")
    .permissions([]) # FIXME add read permission
    .params(["repo_id", :repo_id],
            ["export_type", String, "The type of export to create"],
            ["criteria", String, "The criteria for the export", body: true])
    .returns([200, "Id of the newly created export job"]) \
  do

    criteria_raw = JSON.parse(params[:criteria])

    if criteria_raw['user_agent_ref']
      user = User[:agent_record_id => JSONModel(:agent_person).id_for(criteria_raw['user_agent_ref'])] or raise NotFoundException.new("User not found")
      criteria_raw['user'] = {
        'ref' => user.uri,
      }
      criteria_raw.delete('user_agent_ref')
    end

    if criteria_raw['resource_ref']
      criteria_raw['resource'] = {
        'ref' => criteria_raw['resource_ref'],
      }
      criteria_raw.delete('resource_ref')
    end

    if criteria_raw['repository_ref']
      criteria_raw['repository'] = {
        'ref' => criteria_raw['repository_ref'],
      }
      criteria_raw.delete('repository_ref')
    end

    criteria = JSONModel(:activity_stream_export_criteria).from_hash(criteria_raw)

    ActivityStreamExport.validate_criteria!(params[:export_type], criteria)

    export = ActivityStreamExport.queue_with_criteria(params[:export_type], criteria)
    json_response({'id' => export.id, 'job_id' => export.job_id, 'status' => export.status})
  end

  Endpoint.get('/activity-stream-export/:id')
   .description("Fetch an activity stream export")
   .permissions([]) # FIXME add read permission
   .params(["id", Integer, "The ID of the export"]) \
   .returns([200, "Export json"]) \
  do
    json_response(ActivityStreamExport.to_jsonmodel(params[:id]))
  end

  Endpoint.get('/activity-stream-export/:id/download')
    .description("Download an activity stream export")
    .permissions([]) # FIXME add read permission
    .params(["id", Integer, "The ID of the export to download"]) \
    .returns([200, "Stream the activity stream export"]) \
  do
    export = ActivityStreamExport.get_or_die(params[:id])

    if export
      file_path = File.join(AppConfig[:job_file_path], export.export_file_path)

      if file_path && File.exist?(file_path)
        send_file(file_path, :filename => "activity_stream_export.csv", :type => 'text/csv')
      else
        raise NotFoundException.new("Export file not available")
      end
    else
      raise NotFoundException.new("Export job not found")
    end
  end
end
