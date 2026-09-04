require 'audit_event_constants'

class AuditEvent
  W3C_URL = 'https://www.w3.org/ns/activitystreams'
  # FIXME: might need to support a proxy url
  ARCHIVESSPACE_URI = AppConfig[:backend_url]

  def self.ds(db, since = nil, object_type = nil)
    ds = db[:audit_event].left_join(:audit_record, :audit_record__audit_event_id => :audit_event__id)
                         .group(:audit_event__id)
                         .order(Sequel.asc(:audit_event__timestamp))

    unless since.nil?
      since_time = Time.at(since)
      ds = ds.where { timestamp >= since_time }
    end

    if object_type
      ds = ds.filter(:audit_record__type => object_type)
    end

    ds.select(Sequel.as(Sequel.qualify(:audit_event, :id),
                        :event_id),
              :timestamp,
              :actor_name,
              :actor_type,
              :activity_type,
              :change_method,
              Sequel.function(:GROUP_CONCAT, Sequel.function(:CONCAT_WS, ":", :audit_record__role, :audit_record__type, :audit_record__uri)).as(:records))
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


    records = {}

    event[:records].split(',').each do |record|
      (role, type, uri) = record.split(':')
      records[role] ||= []
      records[role] << {:uri => uri, :type => type}
    end

    records.each do |role, uris|
      out[ROLE_CODE_TABLE[role.to_i]] = ASUtils.wrap(uris).map{|uri|
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
        render(ds(db).filter(Sequel.qualify(:audit_event, :id) => Integer(event_id)).first)
      end
    end
  end

  def self.by_type(object_type)
    DB.open do |db|
      ds(db, nil, object_type).map{|row| render(row)}
    end
  end

  def self.object_type_codes
    @included_object_types ||= AuditEvent::OPTIONAL_OBJECT_TYPES.select{|oot|
      AppConfig[:audit_logging_include_object_types].include?(AuditEvent::OBJECT_TYPE_CODE_TABLE[oot])
    }

    AuditEvent::OBJECT_TYPES - AuditEvent::OPTIONAL_OBJECT_TYPES + @included_object_types
  end

  def self.object_types
    object_type_codes.map{|otc| AuditEvent::OBJECT_TYPE_CODE_TABLE[otc]}
  end

  def self.all_activity_streams
    object_types.map{|ot| activity_stream_uri("/#{ot}")}
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
        out[:orderedItems] = ds(db, nil, object_type).filter(:audit_event__id => ids).map {|row|
          render(row, include_context: false)
        }
        out
      when 'bulk'
        record_type = AuditEvent::OBJECT_TYPE_CODE_TABLE.fetch(audit_page.page.fetch(:bulk_record_type))
        record_ids = audit_page.event_ids

        record_uris = DB.open do |db|
          model = ASModel.all_models.find {|model|
            jsonmodel = model.my_jsonmodel(true)
            jsonmodel && jsonmodel.record_type == record_type
          }

          raise "Model not found for #{record_type}" unless model

          model.any_repo.filter(id: record_ids).map {|record|
            if record.respond_to?(:repo_id)
              RequestContext.open(repo_id: record.repo_id) do
                [record.id, record.uri]
              end
            else
              [record.id, record.uri]
            end
          }.to_h
        end

        role = AuditEvent::ROLE_OBJECT

        out[:orderedItems] = record_ids.each_with_index.map {|record_id, offset|
          {
            event_id: "_blk_p#{audit_page.page.fetch(:bulk_all_stream_page_number)}o#{offset}",
            timestamp: audit_page.page.fetch(:update_time),
            activity_type: audit_page.page.fetch(:bulk_activity_type),
            change_method: audit_page.page.fetch(:bulk_change_method),
            actor_name: audit_page.page.fetch(:bulk_actor_name),
            actor_type: audit_page.page.fetch(:bulk_actor_type),
            records:[role, record_type, record_uris.fetch(record_id)].join(":")
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
