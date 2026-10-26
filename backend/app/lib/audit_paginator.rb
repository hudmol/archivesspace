require 'securerandom'
require_relative 'jars/RoaringBitmap-1.6.20.jar'

java_import 'org.roaringbitmap.RoaringBitmap'
java_import 'java.nio.ByteBuffer'

class AuditPaginator

  ANY_TYPE = '_all'

  # We'll aim to buffer this many rows before actually inserting unless forced
  ROW_BUFFER_COUNT = 256

  PAGE_SIZE = 500

  # Avoid doing long runs of archiving and hurting responsiveness.  We'll go
  # around again soon enough.
  MAX_PAGES_ARCHIVED_PER_ROUND = 10

  # Likewise for moving pending bulk event pages into the audit_page table.
  MAX_BULK_PAGES_PER_ROUND = 250

  MY_THREAD_ID = SecureRandom.hex

  # A safe margin for how long we might go without touching the lock
  LOCK_EXPIRE_SECONDS = 900

  def self.start
    @thread ||= Thread.new do
      AuditPaginator.new.run
    end
  end

  def run
    loop do
      begin
        AuditPaginator.try_with_page_lock do
          paginate_audit_records
        end
      rescue Exception => e
        Log.error("Unexpected error in AuditPaginator thread: #{e}")
        Log.exception(e)
      ensure
        sleep 5
      end
    end
  end

  def self.try_with_page_lock
    got_lock = false

    DB.open do |db|
      now = Time.now

      if db[:audit_page_lock]
           .filter(Sequel.~(lock_holder: MY_THREAD_ID))
           .where { lock_expire_time >= now }
           .count > 0
        # Early out: someone holds the lock
        Log.debug("AuditPaginator failed to get page lock.  Will skip this run.")
        return
      end

      row = db[:audit_page_lock].for_update.first or
        raise "Could not find a lock in table audit_page_lock.  Did the row get deleted by mistake?"

      if row.fetch(:lock_holder) == MY_THREAD_ID || (row.fetch(:lock_expire_time) && now >= row.fetch(:lock_expire_time))
        # Clear existing/expired lock
        Log.info("Paginator #{MY_THREAD_ID}: Clearing existing/expired lock: #{row}")
        db[:audit_page_lock].filter(id: row.fetch(:id)).update(lock_holder: nil, lock_expire_time: nil)
      end

      got_lock = (db[:audit_page_lock].filter(lock_holder: nil).update(lock_holder: MY_THREAD_ID, lock_expire_time: now + LOCK_EXPIRE_SECONDS) > 0)
    end

    if got_lock
      begin
        yield
      ensure
        # Release the lock
        DB.open do |db|
          db[:audit_page_lock].filter(lock_holder: MY_THREAD_ID).update(lock_holder: nil, lock_expire_time: nil)
        end
      end
    else
      Log.debug("AuditPaginator failed to get page lock.  Will skip this run.")
    end
  end

  def self.refresh_page_lock!
    DB.open do |db|
      now = Time.now
      if db[:audit_page_lock].filter(lock_holder: MY_THREAD_ID).update(lock_expire_time: now + LOCK_EXPIRE_SECONDS) == 0
        raise "AuditPaginator lock refresh failed.  Did we time out while holding the lock?"
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

    def extract_archive
      raise "Can only extract from an archived page" unless self.page_type == 'archived'

      result = JSON.parse(AuditPaginator.decompress(self.page.fetch(:archive)), symbolize_names: true)

      result.each do |event|
        # Rehydrate our date objects
        event[:timestamp] = DateTime.parse(event[:timestamp])
      end

      # :symbolize_names turns a key like "1" into :"1", but our original data
      # structure just wants a bare integer.
      fix_integer_keys!(result)

      result
    end

    def page_type
      self.page.fetch(:page_event_type)
    end

    def etag
      @etag ||= if self.page.fetch(:is_page_complete) == 1 && self.has_next_page
                  Digest::SHA256.hexdigest([self.page.fetch(:page_number), self.page.fetch(:page_filter), self.page.fetch(:update_time)].map(&:to_s).join("\1"))
                else
                  "_" + SecureRandom.hex
                end
    end

    # Only stable pages get a Last-Modified.  update_time doesn't change when
    # a page completes or gains a next page, so If-Modified-Since would
    # otherwise 304 a client into a stale copy.
    def last_modified
      return nil unless self.page.fetch(:is_page_complete) == 1 && self.has_next_page

      self.page.fetch(:update_time, nil)
    end

    private

    def fix_integer_keys!(elt)
      if elt.is_a?(Array)
        elt.each {|e| fix_integer_keys!(e)}
      elsif elt.is_a?(Hash)
        elt.keys.each do |key|
          if key.to_s =~ /\A[0-9]+\z/
            elt[Integer(key.to_s)] = elt.delete(key)
          end
        end

        elt.values.each {|e| fix_integer_keys!(e)}
      end
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

  def self.find_archived_event(db, event_id)
    db[:audit_page]
      .filter(page_event_type: 'archived', page_filter: ANY_TYPE)
      .where { min_id_written <= event_id }
      .where { max_id_written >= event_id }
      .each do |matched_page|

      AuditPage.new(matched_page, nil).extract_archive.each do |event_record|
        if event_record.fetch(:event_id) == event_id
          return event_record
        end
      end
    end

    return nil
  end

  # Allows a caller to mark lots of record IDs as updated in one hit.  Avoids
  # holding too much in memory, and writes pending pages of IDs to a holding
  # table in the DB (like a write-ahead log).
  #
  # The idea is to have the AuditPaginator thread be solely responsible for
  # writes to the `audit_page` table.  Request threads write to the WAL without
  # blocking each other, and the AuditPaginator thread merges it all together
  # without having to worry about concurrent writers.
  BulkIDConsumer = Struct.new(:timestamp, :record_type, :record_type_code, :activity_type, :change_method, :actor_type, :actor_name, :object_repo, :target_repo, :system_generated) do
    def initialize(*)
      super

      @id_set = RoaringBitmap.new
      @inside_transaction = false
      @buffered_pages = []
      @max_allowed_packet = nil
    end

    def transaction
      DB.open do |db|
        @buffered_pages.clear
        @id_set.clear

        @inside_transaction = true

        @max_allowed_packet = db.fetch("select @@max_allowed_packet as max_packet").first[:max_packet].to_i

        if @max_allowed_packet == 0
          # Assume a fairly conservative value
          @max_allowed_packet = 4 * 1024 * 1024
        end

        begin
          yield
        rescue
          @inside_transaction = false
          raise $!
        end
      end
    end

    def <<(record_id)
      @id_set.add(record_id)
      flush
    end

    def flush(force = false)
      raise "AuditPaginator: no transaction" unless @inside_transaction

      # Prepare a new page if there's one to prepare
      if @id_set.cardinality == AuditPaginator::PAGE_SIZE || (@id_set.cardinality > 0 && force)
        @id_set.run_optimize

        @buffered_pages << {
          page_filter: record_type,
          update_time: self.timestamp,
          min_id_written: @id_set.first,
          max_id_written: @id_set.last,
          event_count: @id_set.cardinality,
          id_set: AuditPaginator.id_set_to_bytes(@id_set),
          bulk_record_type: self.record_type_code,
          bulk_activity_type: self.activity_type,
          bulk_change_method: self.change_method,
          bulk_actor_type: self.actor_type,
          bulk_actor_name: self.actor_name,
          bulk_object_repo_id: self.object_repo,
          bulk_target_repo_id: self.target_repo,
          system_generated: self.system_generated,
        }

        @id_set.clear
      end

      # And write to the DB if we're ready to write
      return if @buffered_pages.empty?

      estimated_packet_size = @buffered_pages.map {|page| page.values.map {|field| field.to_s.bytesize }.sum }.sum
      nearing_max_packet = (estimated_packet_size.to_f / @max_allowed_packet.to_f) >= 0.8

      if force || @buffered_pages.length >= ROW_BUFFER_COUNT || nearing_max_packet
        # DB.open just to get the handle: we're already in an outer transaction
        DB.open do |db|
          db[:audit_bulk_page_pending].multi_insert(@buffered_pages)
        end

        Log.info("#{@buffered_pages.length} pending audit page(s) of bulk events written for type #{record_type}")

        @buffered_pages.clear
      end
    end
  end

  def self.add_bulk_events(timestamp:, record_type:, activity_type:, change_method:, actor_type:, actor_name:, object_repo:, target_repo:, system_generated:)
    unless AuditEvent::OBJECT_TYPE_CODE_TABLE.has_key?(record_type)
      raise "Unsupported audit event record type: #{record_type}"
    end

    unless AuditEvent::ACTIVITY_TYPE_CODE_TABLE.has_key?(activity_type)
      raise "Unknown audit event activity type: #{activity_type}"
    end

    unless AuditEvent::CHANGE_METHODS.include?(change_method.to_i)
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
                                     target_repo,
                                     system_generated)
    id_consumer.transaction do
      yield id_consumer
      id_consumer.flush(:force)
    end
  end

  MARK_EVERYTHING_BATCH_SIZE = 100_000

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
          actor_name: 'admin',
          object_repo: nil,
          target_repo: nil,
          system_generated: 1
        ) do |events|
          begin
            min_id = model.min(:id)
            max_id = model.max(:id)

            if min_id && max_id
              loop do
                upper = min_id + MARK_EVERYTHING_BATCH_SIZE

                model.where { (id >= min_id) & (id <= upper) }.select(:id).map(:id).each do |record_id|
                  events << record_id
                end

                break if upper >= max_id

                min_id = upper + 1
              end
            end
          rescue
            Log.error("Failure generating update events for type #{jsonmodel_cls.record_type}: #{$!}")
            Log.exception($!)
            raise $!
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
                                   target_repo: target_repo_id,
                                   system_generated: 0
                                   ) do |events|
      begin
        model.filter(:repo_id => source_repo_id).map(:id).each do |record_id|
          events << record_id
        end
      rescue
        Log.error("Failure generating transfer move events for type #{jsonmodel_cls.record_type}: #{$!}")
        Log.exception($!)
        raise $!
      end
    end
  end

  def self.log_bulk_update(model, record_ids)
    return unless AppConfig[:enable_audit_logging]

    now = Time.now

    jsonmodel_cls = model.my_jsonmodel(true)
    return unless jsonmodel_cls

    record_type_code = AuditEvent.object_type_code_for(jsonmodel_cls.record_type)
    return unless record_type_code

    AuditPaginator.add_bulk_events(
      timestamp: now,
      record_type: record_type_code,
      activity_type: AuditEvent::ACTIVITY_TYPE_UPDATE,
      change_method: RequestContext.get(:change_method) || AuditEvent::CHANGE_METHOD_API,
      actor_type: AuditEvent::ACTOR_TYPE_PERSON,
      actor_name: RequestContext.get(:current_username),
      object_repo: nil,
      target_repo: nil,
      system_generated: 0,
    ) do |events|
      begin
        record_ids.each do |record_id|
          events << record_id
        end
      rescue
        Log.error("Failure generating update events for type #{jsonmodel_cls.record_type}: #{$!}")
        Log.exception($!)
        raise $!
      end
    end
  end


  private

  def paginate_audit_records
    max_sequence = nil

    DB.open do |db|
      AuditPaginator.refresh_page_lock!
      assign_sequence_numbers(db)
      max_sequence = db[:audit_event].max(:sequence)
    end

    drain_pending_bulk_pages

    audit_record_types = DB.open do |db|
      db[:audit_record].select(:type).distinct.map(:type)
    end

    # Paginate per type
    audit_record_types.each do |record_type|
      paginate_audit_records_for_type(record_type)
    end

    # "any type"
    paginate_audit_records_for_type

    archive_pages(max_sequence)
  end

  def archive_pages(max_sequence)
    max_unarchived_pages = AppConfig[:audit_logging_archive_threshold]

    return if max_unarchived_pages.nil?
    return if max_sequence.nil?

    DB.open do |db|
      AuditPaginator.refresh_page_lock!

      # Each stream keeps its own `max_unarchived_pages` most recent pages
      # unarchived, so the cutoff is calculated per page_filter.
      max_page_by_filter = db[:audit_page]
                             .group(:page_filter)
                             .order(:page_filter)
                             .select_hash(:page_filter, Sequel.function(:max, :page_number).as(:max_page))

      archivable_pages = []

      max_page_by_filter.each do |page_filter, max_page|
        max_archivable_page = max_page - max_unarchived_pages

        db[:audit_page]
          .filter(page_filter: page_filter, page_event_type: 'audit', is_page_complete: 1)
          .where { page_number <= max_archivable_page }
          .order(:page_number)
          .limit(MAX_PAGES_ARCHIVED_PER_ROUND)
          .select(:id, :page_number)
          .each do |row|
          if archivable_pages.length < MAX_PAGES_ARCHIVED_PER_ROUND
            archivable_pages << row.fetch(:id)
          else
            break
          end
        end
      end

      # Nothing to archive, and therefore nothing to do
      return if archivable_pages.empty?

      archivable_pages.each do |page_id|
        AuditPaginator.refresh_page_lock!

        row = db[:audit_page].filter(id: page_id).first
        ids = AuditPage.new(row, false).event_ids

        filter = row.fetch(:page_filter)

        if filter == ANY_TYPE
          filter = nil
        end

        events = JSON.dump(AuditEvent.find_events(db, {:object_type => filter, :event_ids => ids}))

        compressed = AuditPaginator.compress(events)

        db[:audit_page]
          .filter(id: row.fetch(:id))
          .update(
            archive: Sequel.blob(compressed),
            page_event_type: 'archived',
            min_id_written: ids.min,
            max_id_written: ids.max,
          )
      end

      # Sweep our audit tables for rows that are now fully archived (not
      # referenced by any 'audit' page)
      live_ids = RoaringBitmap.new
      db[:audit_page].filter(page_event_type: 'audit').each do |row|
        id_set = RoaringBitmap.new
        id_set.deserialize(ByteBuffer.wrap(row.fetch(:id_set)
                                             .force_encoding(Encoding::ASCII_8BIT)
                                             .to_java_bytes))

        live_ids.or(id_set)
      end

      remove_ids = []

      db[:audit_event].each do |audit_event|
        # Events without a sequence number haven't been paginated yet
        next if audit_event.fetch(:sequence).nil?

        # Events greater than max_sequence were added since we started running
        next if audit_event.fetch(:sequence) > max_sequence

        next if live_ids.contains(audit_event.fetch(:id))
        remove_ids << audit_event.fetch(:id)
      end

      unless remove_ids.empty?
        db[:audit_record].filter(audit_event_id: remove_ids).delete
        db[:audit_event].filter(id: remove_ids).delete

        Log.info("Archived #{remove_ids.length} event records")
      end
    end
  end

  def assign_sequence_numbers(db)
    last_sequence_number = [db[:audit_event].max(:sequence),
                            db[:audit_page].max(:last_sequence_written)].compact.max || 0

    loop do
      ids_to_update = db[:audit_event]
                        .filter(:sequence => nil)
                        .limit(1000)
                        .select(:id)
                        .map(:id)

      break if ids_to_update.empty?

      ids_to_update.each do |event_id|
        last_sequence_number += 1
        db[:audit_event].filter(:id => event_id).update(:sequence => last_sequence_number)
      end
    end
  end

  def paginate_audit_records_for_type(record_type = ANY_TYPE)
    filters = { page_filter: record_type, page_event_type: 'audit' }

    loop do
      DB.open do |db|
        AuditPaginator.refresh_page_lock!

        # We may or may not have room in the last page for more records.  Maybe
        # there's no room, or maybe there's no page yet at all.
        page_in_progress = db[:audit_page].filter(filters).filter(is_page_complete: 0).first

        last_sequence_written = 0
        id_set = RoaringBitmap.new

        if page_in_progress
          # Load the partial page and the last event record we saw
          last_sequence_written = page_in_progress.fetch(:last_sequence_written)
          id_set.deserialize(ByteBuffer.wrap(page_in_progress.fetch(:id_set)
                                               .force_encoding(Encoding::ASCII_8BIT)
                                               .to_java_bytes))
        else
          # Archived pages count too: if every page in this stream has been
          # archived, we still need to resume from where the last one left off.
          #
          # Bulk pages are skipped because they don't have a meaningful
          # last_sequence_written value.
          if (last_page = db[:audit_page]
                            .filter(page_filter: record_type, page_event_type: ['audit', 'archived'])
                            .order(Sequel.desc(:page_number))
                            .first)
            last_sequence_written = last_page.fetch(:last_sequence_written)
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

          new_events = audit_dataset.where { sequence > last_sequence_written }.order(:sequence).limit(remaining_entry_count).select(:sequence, :id)
          new_events.each do |row|
            last_sequence_written = row.fetch(:sequence)
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
            .update(min_id_written: id_set.first,
                    max_id_written: id_set.last,
                    last_sequence_written: last_sequence_written,
                    update_time: Time.now,
                    id_set: AuditPaginator.id_set_to_bytes(id_set),
                    event_count: id_set.cardinality,
                    is_page_complete: id_set.cardinality < PAGE_SIZE ? 0 : 1)

          Log.info("Audit page #{page_in_progress.fetch(:page_number)} updated")
        else
          # Time for a new page.
          next_position = next_page_position(db, record_type)

          db[:audit_page]
            .insert(
              filters.merge(
                page_number: next_position.next_page_number,
                update_time: Time.now,
                min_id_written: id_set.first,
                max_id_written: id_set.last,
                last_sequence_written: last_sequence_written,
                is_page_complete: id_set.cardinality < PAGE_SIZE ? 0 : 1,
                cumulative_prior_event_count: next_position.cumulative_prior_event_count,
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

          Log.info("Audit page #{next_position.next_page_number} inserted for type #{record_type}")
        end
      end
    end
  end

  NextPagePosition = Struct.new(:next_page_number, :cumulative_prior_event_count)

  # The page number and cumulative_prior_event_count for the next page
  # appended to the stream for `page_filter`.
  def next_page_position(db, page_filter)
    last_page = db[:audit_page].filter(page_filter: page_filter).max(:page_number) || 0

    cumulative_prior_event_count = if last_page > 0
                                     db[:audit_page]
                                       .filter(page_filter: page_filter, page_number: last_page)
                                       .map {|p| p[:cumulative_prior_event_count] + p[:event_count] }
                                       .first
                                   else
                                     0
                                   end

    NextPagePosition.new(last_page + 1, cumulative_prior_event_count)
  end

  # Move pages of bulk events written by request threads (see BulkIDConsumer)
  # into the activity stream.  Each pending page becomes a page in the ANY_TYPE
  # stream and also one in its own record type's stream.
  def drain_pending_bulk_pages
    DB.open do |db|
      AuditPaginator.refresh_page_lock!

      pending = db[:audit_bulk_page_pending].order(:id).limit(MAX_BULK_PAGES_PER_ROUND).all

      return if pending.empty?

      next_position_by_filter = {}
      new_pages = []

      pending.each do |pending_page|
        AuditPaginator.refresh_page_lock!

        all_stream_page_number = nil

        # ANY_TYPE first, since the per-type page links to its page number
        [ANY_TYPE, pending_page.fetch(:page_filter)].each do |page_filter|
          unless next_position_by_filter.has_key?(page_filter)
            # If there is a page in progress, we want to close it off.  Our
            # events will be next in the activity stream.
            db[:audit_page].filter(page_filter: page_filter, is_page_complete: 0).update(is_page_complete: 1)

            next_position_by_filter[page_filter] = next_page_position(db, page_filter)
          end

          next_position = next_position_by_filter.fetch(page_filter)
          all_stream_page_number ||= next_position.next_page_number

          new_pages << pending_page.reject {|k, _| k == :id}.merge(
            page_filter: page_filter,
            page_event_type: 'bulk',
            page_number: next_position.next_page_number,
            last_sequence_written: -1,
            is_page_complete: 1,
            cumulative_prior_event_count: next_position.cumulative_prior_event_count,
            id_set: Sequel.blob(pending_page.fetch(:id_set)),
            bulk_all_stream_page_number: all_stream_page_number,
          )

          next_position.next_page_number += 1
          next_position.cumulative_prior_event_count += pending_page.fetch(:event_count)
        end
      end

      db[:audit_page].multi_insert(new_pages, :slice => ROW_BUFFER_COUNT)
      db[:audit_bulk_page_pending].filter(id: pending.map {|row| row.fetch(:id)}).delete

      Log.info("#{pending.length} pending bulk audit page(s) added to the activity stream")
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

  def self.compress(string)
    out_bytes = java.io.ByteArrayOutputStream.new

    gzip = java.util.zip.GZIPOutputStream.new(out_bytes)
    gzip.write(string.to_java_bytes)
    gzip.close

    String.from_java_bytes(out_bytes.to_byte_array)
  end

  def self.decompress(gzip_bytes)
    in_bytes = java.io.ByteArrayInputStream.new(gzip_bytes.to_java_bytes)
    out_bytes = java.io.ByteArrayOutputStream.new

    gzip = java.util.zip.GZIPInputStream.new(in_bytes)

    buf = Java::byte[4096].new

    while ((len = gzip.read(buf, 0, buf.length)) >= 0)
      out_bytes.write(buf, 0, len)
    end

    gzip.close

    java.lang.String.new(out_bytes.to_byte_array,
                         java.nio.charset.StandardCharsets::UTF_8)
  end

end
