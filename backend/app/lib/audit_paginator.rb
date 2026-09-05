require_relative 'jars/RoaringBitmap-1.6.20.jar'

java_import 'org.roaringbitmap.RoaringBitmap'
java_import 'java.nio.ByteBuffer'

class AuditPaginator

  ANY_TYPE = '_all'

  PAGE_SIZE = 500

  def self.start
    @thread ||= Thread.new do
      AuditPaginator.new.run
    end
  end

  def run
    loop do
      begin
        paginate_audit_records
      rescue Exception => e
        Log.error("Unexpected error in AuditPaginator thread: #{e}")
        Log.exception(e)
      ensure
        sleep 5
      end
    end
  end

  PageStatistics = Struct.new(:total, :last_page)

  def self.page_statistics(db, object_type)
    object_type ||= ANY_TYPE

    total = db[:audit_page].filter(page_filter: object_type).sum(:event_count).to_i
    last_page = db[:audit_page].filter(page_filter: object_type).max(:page_number)

    PageStatistics.new(total, last_page)
  end

  AuditPage = Struct.new(:page, :has_next_page) do
    def event_ids
      id_set = RoaringBitmap.new
      id_set.deserialize(ByteBuffer.wrap(self.page.fetch(:id_set)
                                           .force_encoding(Encoding::ASCII_8BIT)
                                           .to_java_bytes))

      id_set.to_a
    end

    def page_type
      self.page.fetch(:page_event_type)
    end
  end

  def self.get_page(db, page, object_type)
    object_type ||= ANY_TYPE

    page_ds = db[:audit_page]
                .filter(page_filter: object_type)

    requested_page = page_ds.filter(:page_number => page).first

    return nil unless requested_page

    has_next_page = requested_page.fetch(:is_page_complete) == 1 && page_ds.filter(:page_number => page + 1).count > 0

    AuditPage.new(requested_page, has_next_page)
  end

  BulkIDConsumer = Struct.new(:timestamp, :record_type, :record_type_code, :activity_type, :change_method, :actor_type, :actor_name, :object_repo, :target_repo) do
    def initialize(*)
      super

      @id_set = RoaringBitmap.new
      @inside_transaction = false
    end

    def transaction
      DB.open do |_db|
        @inside_transaction = true
        begin
          yield
        rescue
          @inside_transaction = false
        end
      end
    end

    def <<(record_id)
      @id_set.add(record_id)
      flush
    end

    def flush(force = false)
      raise "AuditPaginator: no transaction" unless @inside_transaction

      if @id_set.cardinality == AuditPaginator::PAGE_SIZE || (@id_set.cardinality > 0 && force)
        @id_set.run_optimize

        new_pages = {}

        [ANY_TYPE, record_type].each do |type_limit|
          filters = { page_filter: type_limit }

          # DB.open just to get the handle: we're already in an outer transaction
          DB.open do |db|
            AuditPaginator.lock_page_table!(db)

            # If there is a page in progress, we want to close it off.  Our
            # events will be next in the activity stream.
            db[:audit_page].filter(filters).filter(is_page_complete: 0).update(is_page_complete: 1)

            # Time for a new page
            last_page = db[:audit_page].filter(filters).max(:page_number) || 0

            cumulative_prior_event_count = if last_page > 0
                                             db[:audit_page]
                                               .filter(filters)
                                               .filter(page_number: last_page)
                                               .map {|p| p[:cumulative_prior_event_count] + p[:event_count] }
                                               .first
                                           else
                                             0
                                           end

            new_pages[type_limit] = last_page + 1

            db[:audit_page]
              .insert(
                filters.merge(
                  page_event_type: 'bulk',
                  page_number: last_page + 1,
                  update_time: self.timestamp,
                  last_id_written: -1,
                  is_page_complete: 1,
                  event_count: @id_set.cardinality,
                  cumulative_prior_event_count: cumulative_prior_event_count,
                  id_set: AuditPaginator.id_set_to_bytes(@id_set),
                  bulk_record_type: self.record_type_code,
                  bulk_activity_type: self.activity_type,
                  bulk_change_method: self.change_method,
                  bulk_actor_type: self.actor_type,
                  bulk_actor_name: self.actor_name,
                  bulk_object_repo_id: self.object_repo,
                  bulk_target_repo_id: self.target_repo,

                  # Note: requirement that we process ANY_TYPE first because we
                  # depend on its page for subsequent inserts.
                  bulk_all_stream_page_number: new_pages.fetch(ANY_TYPE)
                )
              )

            Log.info("Audit page #{last_page + 1} of #{@id_set.cardinality} bulk events inserted for type #{record_type}")
          end
        end

        @id_set.clear
      end

    end
  end

  def self.add_bulk_events(timestamp:, record_type:, activity_type:, change_method:, actor_type:, actor_name:, object_repo:, target_repo:)
    unless AuditEvent::OBJECT_TYPE_CODE_TABLE.has_key?(record_type)
      raise "Unsupported audit event record type: #{record_type}"
    end

    unless AuditEvent::ACTIVITY_TYPE_CODE_TABLE.has_key?(activity_type)
      raise "Unknown audit event activity type: #{activity_type}"
    end

    unless AuditEvent::CHANGE_METHODS.include?(change_method)
      raise "Unknown audit event change method: #{change_method}"
    end

    unless AuditEvent::ACTOR_TYPES.include?(actor_type)
      raise "Unknown audit event actor type: #{actor_type}"
    end

    id_consumer = BulkIDConsumer.new(timestamp,
                                     AuditEvent::OBJECT_TYPE_CODE_TABLE.fetch(record_type),
                                     record_type,
                                     activity_type,
                                     change_method,
                                     actor_type,
                                     actor_name,
                                     object_repo,
                                     target_repo)
    id_consumer.transaction do
      yield id_consumer
      id_consumer.flush(:force)
    end
  end

  def self.mark_everything_updated!
    now = Time.now

    audited_code_by_record_name = AuditEvent.object_type_codes.map {|code|
      [AuditEvent::OBJECT_TYPE_CODE_TABLE.fetch(code), code]
    }.to_h

    ASModel.all_models.each do |model|
      jsonmodel_cls = model.my_jsonmodel(true)
      if jsonmodel_cls && audited_code_by_record_name.has_key?(jsonmodel_cls.record_type)
        Log.info("Generating update events for all records of type #{jsonmodel_cls.record_type}")

        AuditPaginator.add_bulk_events(
          timestamp: now,
          record_type: audited_code_by_record_name.fetch(jsonmodel_cls.record_type),
          activity_type: AuditEvent::ACTIVITY_TYPE_UPDATE,
          change_method: AuditEvent::CHANGE_METHOD_MIGRATION,
          actor_type: AuditEvent::ACTOR_TYPE_APPLICATION,
          actor_name: 'admin'
        ) do |events|
          begin
            model.map(:id).each do |record_id|
              events << record_id
            end
          rescue
            Log.error("Failure generating update events for type #{jsonmodel_cls.record_type}: #{$!}")
            Log.exception($!)
          end
        end
      end
    end
  end

  def self.log_bulk_transfer(model, source_repo_id, target_repo_id)
    return unless AppConfig[:enable_audit_logging]

    now = Time.now

    jsonmodel_cls = model.my_jsonmodel(true)
    return unless jsonmodel_cls

    record_type_code = AuditEvent.object_type_code_for(jsonmodel_cls.record_type)
    return unless record_type_code

    AuditPaginator.add_bulk_events(
                                   timestamp: now,
                                   record_type: record_type_code,
                                   activity_type: AuditEvent::ACTIVITY_TYPE_MOVE,
                                   change_method: AuditEvent::CHANGE_METHOD_TRANSFER,
                                   actor_type: AuditEvent::ACTOR_TYPE_PERSON,
                                   actor_name: RequestContext.get(:current_username),
                                   object_repo: source_repo_id,
                                   target_repo: target_repo_id
                                   ) do |events|
      begin
        model.filter(:repo_id => source_repo_id).map(:id).each do |record_id|
          events << record_id
        end
      rescue
        Log.error("Failure generating transfer move events for type #{jsonmodel_cls.record_type}: #{$!}")
        Log.exception($!)
      end
    end



  end

  private

  def paginate_audit_records
    audit_record_types = DB.open do |db|
      db[:audit_record].select(:type).distinct.map(:type)
    end

    # Paginate per type
    audit_record_types.each do |record_type|
      paginate_audit_records_for_type(record_type)
    end

    # "any type"
    paginate_audit_records_for_type
  end

  def paginate_audit_records_for_type(record_type = ANY_TYPE)
    filters = { page_filter: record_type, page_event_type: 'audit' }

    loop do
      DB.open do |db|
        AuditPaginator.lock_page_table!(db)

        # We may or may not have room in the last page for more records.  Maybe
        # there's no room, or maybe there's no page yet at all.
        page_in_progress = db[:audit_page].filter(filters).filter(is_page_complete: 0).first

        last_id_written = 0
        id_set = RoaringBitmap.new

        if page_in_progress
          # Load the partial page and the last event record we saw
          last_id_written = page_in_progress.fetch(:last_id_written)
          id_set.deserialize(ByteBuffer.wrap(page_in_progress.fetch(:id_set)
                                               .force_encoding(Encoding::ASCII_8BIT)
                                               .to_java_bytes))
        else
          if (last_page = db[:audit_page].filter(filters).order(Sequel.desc(:page_number)).first)
            last_id_written = last_page.fetch(:last_id_written)
          end
        end

        remaining_entry_count = PAGE_SIZE - id_set.cardinality
        page_updated = false

        if remaining_entry_count <= 0
          # Write the completed page
          Log.debug("Weird: found a full page not marked as completed")
          page_updated = true
        else
          # Fill out as many extra events as we can fit in the current (or new) page
          audit_dataset = if record_type == ANY_TYPE
                            db[:audit_event]
                          else
                            db[:audit_event].where(
                              db[:audit_record]
                                .where(audit_event_id: Sequel.qualify(:audit_event, :id), type: record_type)
                                .exists
                            )
                          end

          new_events = audit_dataset.where { id > last_id_written }.limit(remaining_entry_count).select(:id)
          new_events.each do |row|
            last_id_written = row.fetch(:id)
            id_set.add(row.fetch(:id))
            page_updated = true
          end
        end

        return unless page_updated

        id_set.run_optimize

        if page_in_progress
          # Update the existing page
          db[:audit_page]
            .filter(id: page_in_progress.fetch(:id))
            .update(last_id_written: last_id_written,
                    update_time: Time.now,
                    id_set: AuditPaginator.id_set_to_bytes(id_set),
                    event_count: id_set.cardinality,
                    is_page_complete: id_set.cardinality < PAGE_SIZE ? 0 : 1)

          Log.info("Audit page #{page_in_progress.fetch(:page_number)} updated")
        else
          # Time for a new page.
          last_page = db[:audit_page].filter(page_filter: record_type).max(:page_number) || 0

          cumulative_prior_event_count = if last_page > 0
                                           db[:audit_page]
                                             .filter(page_filter: record_type, page_number: last_page)
                                             .map {|p| p[:cumulative_prior_event_count] + p[:event_count] }
                                             .first
                                         else
                                           0
                                         end

          db[:audit_page]
            .insert(
              filters.merge(
                page_number: last_page + 1,
                update_time: Time.now,
                last_id_written: last_id_written,
                is_page_complete: id_set.cardinality < PAGE_SIZE ? 0 : 1,
                cumulative_prior_event_count: cumulative_prior_event_count,
                event_count: id_set.cardinality,
                id_set: AuditPaginator.id_set_to_bytes(id_set),

                # These fields not used by regular audit events
                bulk_record_type: 0,
                bulk_activity_type: 0,
                bulk_change_method: 0,
                bulk_actor_type: 0,
                bulk_actor_name: '',
                bulk_object_repo_id: nil,
                bulk_target_repo_id: nil,

              )
            )

          Log.info("Audit page #{last_page + 1} inserted for type #{record_type}")
        end
      end
    end
  end

  def self.id_set_to_bytes(id_set)
    array = Java::byte[id_set.serialized_size_in_bytes].new
    id_set.serialize(ByteBuffer.wrap(array))

    result = String.from_java_bytes(array)
    result.force_encoding(Encoding::ASCII_8BIT)

    Sequel.blob(result)
  end

  def debug_id_set(id_set)
    "#id_set[" + id_set.to_a.join(",") + "]"
  end

  def self.lock_page_table!(db)
    db[:audit_page_lock].for_update.first or
      raise "Could not find a lock in table audit_page_lock.  Did the row get deleted by mistake?"
  end

end
