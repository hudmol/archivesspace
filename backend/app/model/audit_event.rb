require 'audit_event_constants'

class AuditEvent
  W3C_URL = 'https://www.w3.org/ns/activitystreams'
  # FIXME: might need to support a proxy url
  ARCHIVESSPACE_URI = AppConfig[:backend_url]

  def self.find_events(db, opts = {})
    ds = db[:audit_event].left_join(:audit_record, :audit_record__audit_event_id => :audit_event__id)
                         .order(Sequel.asc(:audit_event__timestamp))

    if opts[:since]
      since_time = Time.at(opts[:since])
      ds = ds.where { timestamp >= since_time }
    end

    if opts[:object_type]
      ds = ds.filter(:audit_record__type => opts[:object_type])
    end

    if opts[:event_ids]
      ds = ds.filter(:audit_event__id => opts[:event_ids])
    end

    ds = ds.select(Sequel.as(:audit_event__id, :event_id),
                   :timestamp,
                   :actor_name,
                   :actor_type,
                   :activity_type,
                   :change_method,
                   Sequel.as(:audit_record__uri, :record_uri),
                   Sequel.as(:audit_record__type, :record_type),
                   Sequel.as(:audit_record__role, :record_role)
                   )

    out = []

    ds.each do |row|
      record = {
        row[:record_role] => [{:uri => row[:record_uri], :type => row[:record_type]}]
      }

      if event = out.find {|event| event[:event_id] == row[:event_id] }
        event[:records][row[:record_role]] ||= []
        event[:records][row[:record_role]].push(record[row[:record_role]].first)
      else
        out.push(row.except(:record_uri, :record_type, :record_role).merge(:records => record))
      end
    end

    out
  end

  def self.archivesspace_uri(uri = '')
    if (AppConfig[:activity_stream_use_relative_uris] rescue false)
      uri
    else
      "#{ARCHIVESSPACE_URI}#{uri}"
    end
  end

  def self.activity_stream_uri(uri = '')
    archivesspace_uri("/activity-stream#{uri}")
  end

  def self.render(event, include_context: true)
    return nil if event.nil?

    out = {}

    out['@context'] = W3C_URL if include_context

    out[:id] = activity_stream_uri("/event/#{event[:event_id]}")
    out[:endTime] = event[:timestamp].rfc3339
    out[:actor] = {
      :type => ACTOR_TYPE_CODE_TABLE[event[:actor_type]],
      :name => event[:actor_name]
    }
    out[:type] = ACTIVITY_TYPE_CODE_TABLE[event[:activity_type]]
    out[:method_of_change] = CHANGE_METHOD_CODE_TABLE[event[:change_method]]

    event[:records].each do |role, uris|
      out[ROLE_CODE_TABLE[role.to_i]] = uris.map{|uri|
        {
          :id => archivesspace_uri(uri[:uri]),
          :type => uri[:type]
        }
      }

      if uris.length == 1
        out[ROLE_CODE_TABLE[role.to_i]] = out[ROLE_CODE_TABLE[role.to_i]].first
      end
    end

    # Special handling for merges
    # A merge is a special case of move where the target is included in the list of objects
    # and there are two or more objects. This is marked with a summary of 'merge'
    # Note, the case where there is one object and one target and they are the same is a
    # component move, not a merge
    if out[:type] == ACTIVITY_TYPE_CODE_TABLE[ACTIVITY_TYPE_MOVE] &&
        ASUtils.wrap(out[ROLE_CODE_TABLE[ROLE_OBJECT]]).length > 1 &&
        ASUtils.wrap(out[ROLE_CODE_TABLE[ROLE_OBJECT]]).map{|o| o[:id]}.include?(out[ROLE_CODE_TABLE[ROLE_TARGET]][:id])
      out[:summary] = 'merge'
    end

    out
  end

  def self.by_id(event_id)
    if event_id.start_with?("_blk")
      # Batch event
      if event_id =~ /\A_blk_p([0-9]+)o([0-9]+)\z/
        page_number = Integer($1)
        offset = Integer($2)

        rendered_page = self.page(page_number)

        rendered_page.fetch(:orderedItems).fetch(offset).merge('@context' => W3C_URL)
      else
        return nil
      end
    else
      # Regular single event (by id)
      DB.open do |db|
        event_id = Integer(event_id)
        if (event = find_events(db, {:event_ids => event_id}).first)
          return render(event)
        elsif (archived_event = AuditPaginator.find_archived_event(db, event_id))
          return render(archived_event)
        end
      end
    end
  end

  def self.by_type(object_type)
    DB.open do |db|
      find_events(db, {:object_type => object_type}).map{|row| render(row)}
    end
  end

  def self.object_type_codes
    @included_object_types = AuditEvent::OPTIONAL_OBJECT_TYPES.select{|oot|
      AppConfig[:audit_logging_include_object_types].include?(AuditEvent::OBJECT_TYPE_CODE_TABLE[oot])
    }

    AuditEvent::OBJECT_TYPES - AuditEvent::OPTIONAL_OBJECT_TYPES + @included_object_types
  end

  def self.object_types
    object_type_codes.map{|otc| AuditEvent::OBJECT_TYPE_CODE_TABLE[otc]}
  end

  def self.object_type_code_for(type)
    AuditEvent::OBJECT_TYPE_CODE_TABLE.invert.fetch(type, nil)
  end

  def self.all_activity_streams
    object_types.map{|ot| activity_stream_uri("/#{ot}")}
  end

  def self.change_method_for_import_type(import_type)
    AuditEvent::IMPORTER_CHANGE_METHOD_MAP.fetch(import_type, AuditEvent::CHANGE_METHOD_IMPORTER)
  end

  def self.activity_stream(object_type = nil)
    DB.open do |db|
      page_info = AuditPaginator.page_statistics(db, object_type)

      uri = activity_stream_uri
      if object_type
        uri += "/#{object_type}"
      end

      if page_info.total == 0
        {
          '@context' => W3C_URL,
          :type => 'OrderedCollection',
          :totalItems => page_info.total,
        }
      else
        {
          '@context' => W3C_URL,
          :type => 'OrderedCollection',
          :totalItems => page_info.total,
          :first => uri + "/page/1",
          :last => uri + "/page/#{page_info.last_page}",
        }
      end
    end
  end

  def self.page(page, object_type = nil)
    DB.open do |db|
      uri = activity_stream_uri
      if object_type
        uri += "/#{object_type}"
      end

      audit_page = AuditPaginator.get_page(db, page, object_type)

      return nil unless audit_page

      out = {
        '@context' => W3C_URL,
        :type => 'OrderedCollectionPage',
        :id => "#{uri}/page/#{page}",
        :partOf => {
          :id => uri,
          :type => 'OrderedCollection'
        }
      }

      if page > 1
        out[:prev] = {
          :id => "#{uri}/page/#{page - 1}",
          :type => 'OrderedCollectionPage',
        }
      end

      if audit_page.has_next_page
        out[:next] = {
          :id => "#{uri}/page/#{page + 1}",
          :type => 'OrderedCollectionPage',
        }
      end

      case audit_page.page_type
      when 'audit'
        ids = audit_page.event_ids
        out[:orderedItems] = find_events(db, {:event_ids => ids, :object_type => object_type}).map {|row|
          render(row, include_context: false)
        }
        out
      when 'archived'
        out[:orderedItems] = audit_page.extract_archive.map {|row|
          render(row, include_context: false)
        }
        out
      when 'bulk'
        record_type = AuditEvent::OBJECT_TYPE_CODE_TABLE.fetch(audit_page.page.fetch(:bulk_record_type))
        record_ids = audit_page.event_ids

        # {id: {role: uri}
        record_uri_for_id = {}

        DB.open do |db|
          model = ASModel.all_models.find {|model|
            jsonmodel = model.my_jsonmodel(true)
            jsonmodel && jsonmodel.record_type == record_type
          }

          raise "Model not found for #{record_type}" unless model

          if audit_page.page[:bulk_object_repo_id]
            # Bulk transfers give us all the repository information we need in
            # the audit page itself, so constructing the URI is straightforward.
            record_ids.each do |record_id|
              record_uri_for_id[record_id] = {
                AuditEvent::ROLE_OBJECT => model.my_jsonmodel.uri_for(record_id, repo_id: audit_page.page[:bulk_object_repo_id]),
                AuditEvent::ROLE_TARGET => model.my_jsonmodel.uri_for(record_id, repo_id: audit_page.page[:bulk_target_repo_id])
              }
            end
          else
            # Other bulk pages tell us the types and record IDs that were
            # implicated, but it's up to us to reconstruct the URIs.  For live
            # records, no problem, but finding the original URI of deleted
            # records takes some extra work.

            # Find the live records
            model.any_repo.filter(id: record_ids).each do |record|
              if record.respond_to?(:repo_id)
                RequestContext.open(repo_id: record.repo_id) do
                  record_uri_for_id[record.id] = {AuditEvent::ROLE_OBJECT => record.uri}
                end
              else
                record_uri_for_id[record.id] = {AuditEvent::ROLE_OBJECT => record.uri}
              end
            end

            # Anything still not found must have been deleted
            (record_ids - record_uri_for_id.keys).each do |deleted_record_id|
              if model.model_scope == :repository
                # Interrogate our tombstones to find the repository of the original record.
                db[:deleted_records].filter(:record_id => deleted_record_id).select(:uri).each do |tombstone|
                  parsed = JSONModel.parse_reference(tombstone.fetch(:uri))

                  if parsed[:type] == model.my_jsonmodel.record_type
                    # That's us!
                    record_uri_for_id[deleted_record_id] = {AuditEvent::ROLE_OBJECT => tombstone.fetch(:uri)}
                    break
                  end
                end

                if !record_uri_for_id[deleted_record_id]
                  # This should never happen, since records either exist or
                  # are deleted.  If we're here, someone has likely messed
                  # directly with their database at some point.
                  #
                  # We'll fall back to giving out a URL that will never be
                  # found.  Consumers of the API who try to fetch this will
                  # get a 404, which is what they were going to get on a
                  # deleted record anyway.
                  record_uri_for_id[deleted_record_id] = {AuditEvent::ROLE_OBJECT => model.my_jsonmodel.uri_for(deleted_record_id, :repo_id => Repository.global_repo_id)}
                end
              else
                # Global-scoped records are straightforward.
                record_uri_for_id[deleted_record_id] = {AuditEvent::ROLE_OBJECT => model.my_jsonmodel.uri_for(deleted_record_id)}
              end
            end
          end
        end

        out[:orderedItems] = record_ids.each_with_index.map {|record_id, offset|
          records = {}
          record_uri_for_id.fetch(record_id).each{|role, uri|
            records[role] = [{uri: uri, type: record_type}]
          }

          {
            event_id: "_blk_p#{audit_page.page.fetch(:bulk_all_stream_page_number)}o#{offset}",
            timestamp: audit_page.page.fetch(:update_time),
            activity_type: audit_page.page.fetch(:bulk_activity_type),
            change_method: audit_page.page.fetch(:bulk_change_method),
            actor_name: audit_page.page.fetch(:bulk_actor_name),
            actor_type: audit_page.page.fetch(:bulk_actor_type),
            records: records
          }
        }.map {|row| render(row, include_context: false)}

        out
      else
        raise "Unknown page type: #{audit_page.page_type}"
      end
    end
  end

  def self.log_event(activity_type, records, opts = {})
    return unless AppConfig[:enable_audit_logging]

    if records.values.flatten.compact.empty?
      # Don't log an event if there are no affected records
      # This can happen when nested records are updated, via create_from_json
      return
    end

    unless ACTIVITY_TYPES.include?(activity_type)
      Log.warn("Failed to log Audit Event - unsupported Activity Type: #{activity_type}")
      return
    end

    unless opts[:actor]
      if username = RequestContext.get(:current_username)
        opts[:actor] = username
      else
        Log.warn("Failed to log Audit Event - no Actor provided and no current username")
        return
      end
    end

    records_to_be_logged = {}

    records.each do |role, uris|
      ASUtils.wrap(uris).each do |uri|
        parsed = JSONModel.parse_reference(uri)

        if parsed.nil?
          Log.warn("Failed to log Audit Event Record - failed to parse URI: #{uri}")
          next
        end

        unless object_types.include?(parsed[:type])
          Log.debug("Skipping Audit Record - unsupported Object Type: #{parsed[:type]}")
          next
        end

        records_to_be_logged[role] ||= []
        records_to_be_logged[role] << {:uri => uri, :type => parsed[:type]}
      end
    end

    if records_to_be_logged.empty?
      return
    end

    change_method = RequestContext.get(:change_method) || CHANGE_METHOD_API

    DB.open do |db|
      event_id = db[:audit_event].insert(:timestamp => Time.now,
                                         :actor_name => opts[:actor],
                                         :actor_type => opts[:actor_type] || ACTOR_TYPE_PERSON,
                                         :activity_type => activity_type,
                                         :change_method => change_method)

      records_to_be_logged.each do |role, records|
        records.each do |record|
          db[:audit_record].insert(:audit_event_id => event_id,
                                   :uri => record[:uri],
                                   :type => record[:type],
                                   :role => role)
        end
      end
    end
  end
end
