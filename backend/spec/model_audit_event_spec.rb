require 'spec_helper'
require_relative '../../common/db/migrations/utils'

describe 'AuditEvent model' do

  def create_audit_event(timestamp:, activity_type:, records:, actor_name: 'admin',
                         actor_type: AuditEvent::ACTOR_TYPE_PERSON,
                         change_method: AuditEvent::CHANGE_METHOD_API)
    event_id = $testdb[:audit_event].insert(:timestamp => timestamp,
                                            :actor_name => actor_name,
                                            :actor_type => actor_type,
                                            :activity_type => activity_type,
                                            :change_method => change_method)

    records.each do |record|
      $testdb[:audit_record].insert(:audit_event_id => event_id,
                                    :uri => record[:uri],
                                    :type => record[:type],
                                    :role => record[:role])
    end

    {:id => event_id, :timestamp => timestamp}
  end

  def capture_log_event_calls
    calls = []

    allow(AuditEvent).to receive(:log_event) do |activity_type, records, opts = {}|
      calls << {
        :activity_type => activity_type,
        :records => records,
        :opts => opts,
        :change_method => RequestContext.get(:change_method)
      }
    end

    calls
  end

  def enable_audit_logging
    allow(AppConfig).to receive(:[]).and_call_original
    allow(AppConfig).to receive(:[]).with(:enable_audit_logging).and_return(true)

    allow(AppConfig).to receive(:[]).with(:audit_logging_include_object_types).and_return(['accession', 'assessment'])
  end

  def reset_audit_tables
    # Start fresh to make it easier to test (rolls back after each test)
    $testdb[:audit_page].delete
    $testdb[:audit_record].delete
    $testdb[:audit_event].delete
  end

  def create_bulk_top_container_page(timestamp:, top_container_ids:, actor_name: 'bulk_user')
    AuditPaginator.add_bulk_events(:timestamp => timestamp,
                                   :record_type => AuditEvent::OBJECT_TYPE_TOP_CONTAINER,
                                   :activity_type => AuditEvent::ACTIVITY_TYPE_UPDATE,
                                   :change_method => AuditEvent::CHANGE_METHOD_BULK,
                                   :actor_type => AuditEvent::ACTOR_TYPE_PERSON,
                                   :actor_name => actor_name,
                                   :object_repo => nil,
                                   :target_repo => nil) do |consumer|
      top_container_ids.each do |id|
        consumer << id
      end
    end
  end

  before(:each) do
    enable_audit_logging
    @resource = create(:json_resource)
    @another_resource = create(:json_resource)
    @accession = create(:json_accession)
  end

  it 'marks merge events when there are multiple objects and the target is one of them' do
    rendered = AuditEvent.render({
                                   :timestamp => Time.utc(2024, 1, 1, 10, 0, 0),
                                   :actor_name => 'admin',
                                   :actor_type => AuditEvent::ACTOR_TYPE_PERSON,
                                   :activity_type => AuditEvent::ACTIVITY_TYPE_MOVE,
                                   :change_method => AuditEvent::CHANGE_METHOD_API,
                                   :records => "#{AuditEvent::ROLE_OBJECT}:resource:#{@resource.uri}," \
                                               "#{AuditEvent::ROLE_OBJECT}:resource:#{@another_resource.uri}," \
                                               "#{AuditEvent::ROLE_TARGET}:resource:#{@resource.uri}"
                                 })

    expect(rendered[:type]).to eq('Move')
    expect(rendered[:summary]).to eq('merge')
    expect(rendered['target'][:id]).to eq(AuditEvent.archivesspace_uri(@resource.uri))
  end

  it 'does not mark a move as a merge when there is only one object, even though the target is the same' do
    rendered = AuditEvent.render({
                                   :timestamp => Time.utc(2024, 1, 1, 10, 0, 0),
                                   :actor_name => 'admin',
                                   :actor_type => AuditEvent::ACTOR_TYPE_PERSON,
                                   :activity_type => AuditEvent::ACTIVITY_TYPE_MOVE,
                                   :change_method => AuditEvent::CHANGE_METHOD_API,
                                   :records => "#{AuditEvent::ROLE_OBJECT}:resource:#{@resource.uri}," \
                                               "#{AuditEvent::ROLE_TARGET}:resource:#{@resource.uri}"
                                 })

    expect(rendered[:type]).to eq('Move')
    expect(rendered[:summary]).to be_nil
    expect(rendered['target'][:id]).to eq(AuditEvent.archivesspace_uri(@resource.uri))
  end

  it 'returns an empty ordered collection when there are no audit events' do
    $testdb[:audit_record].delete
    $testdb[:audit_event].delete

    response = AuditEvent.activity_stream

    expect(response[:type]).to eq('OrderedCollection')
    expect(response[:totalItems]).to eq(0)
    expect(response).not_to have_key(:first)
    expect(response).not_to have_key(:last)
  end

  it 'builds filtered activity stream pages with the expected navigation links' do
    top_container = create(:json_top_container)

    (AuditPaginator::PAGE_SIZE + 1).times do
      json = TopContainer.to_jsonmodel(top_container.id)
      TopContainer[top_container.id].update_from_json(json)
    end

    AuditPaginator.new.send(:paginate_audit_records)
    response = AuditEvent.page(2, 'top_container')

    expect(response[:type]).to eq('OrderedCollectionPage')
    expect(response[:prev][:id]).to eq(AuditEvent.activity_stream_uri('/top_container/page/1'))
    expect(response).not_to have_key(:next)
    expect(response[:orderedItems].length).to be > 0
    expect(response[:orderedItems][0][:id]).to match %r{activity-stream/event/}
    expect(response[:orderedItems][0]['object'][:id]).to eq(AuditEvent.archivesspace_uri(top_container.uri))
  end

  describe 'bulk page rendering' do
    it 'splits a bulk batch larger than page size across pages in order' do
      reset_audit_tables

      top_containers = (AuditPaginator::PAGE_SIZE + 1).times.map { create(:json_top_container) }
      create_bulk_top_container_page(:timestamp => Time.utc(2024, 1, 1, 12, 0, 0),
                                     :top_container_ids => top_containers.map(&:id))

      page_1 = AuditEvent.page(1, 'top_container')
      page_2 = AuditEvent.page(2, 'top_container')

      expect(page_1[:next][:id]).to eq(AuditEvent.activity_stream_uri('/top_container/page/2'))
      expect(page_2[:prev][:id]).to eq(AuditEvent.activity_stream_uri('/top_container/page/1'))
      expect(page_2).not_to have_key(:next)

      expect(page_1[:orderedItems].length).to eq(AuditPaginator::PAGE_SIZE)
      expect(page_2[:orderedItems].length).to eq(1)

      expect(page_1[:orderedItems].first[:id]).to eq(AuditEvent.activity_stream_uri('/event/_blk_p1o0'))
      expect(page_1[:orderedItems].last[:id]).to eq(AuditEvent.activity_stream_uri('/event/_blk_p1o499'))
      expect(page_2[:orderedItems].first[:id]).to eq(AuditEvent.activity_stream_uri('/event/_blk_p2o0'))

      expect(page_1[:orderedItems].first['object'][:id]).to eq(AuditEvent.archivesspace_uri(top_containers.first.uri))
      expect(page_1[:orderedItems].last['object'][:id]).to eq(AuditEvent.archivesspace_uri(top_containers[AuditPaginator::PAGE_SIZE - 1].uri))
      expect(page_2[:orderedItems].first['object'][:id]).to eq(AuditEvent.archivesspace_uri(top_containers.last.uri))
    end

    it 'retains page ordering for sequential bulk pages' do
      top_container_1 = create(:json_top_container)
      top_container_2 = create(:json_top_container)
      reset_audit_tables

      first_timestamp = Time.utc(2024, 1, 1, 10, 0, 0)
      second_timestamp = Time.utc(2024, 1, 1, 11, 0, 0)

      create_bulk_top_container_page(:timestamp => first_timestamp, :top_container_ids => [top_container_1.id])
      create_bulk_top_container_page(:timestamp => second_timestamp, :top_container_ids => [top_container_2.id])

      first_page = AuditEvent.page(1, 'top_container')
      second_page = AuditEvent.page(2, 'top_container')

      expect(first_page[:next][:id]).to eq(AuditEvent.activity_stream_uri('/top_container/page/2'))
      expect(second_page[:prev][:id]).to eq(AuditEvent.activity_stream_uri('/top_container/page/1'))
      expect(second_page).not_to have_key(:next)

      expect(first_page[:orderedItems][0][:id]).to eq(AuditEvent.activity_stream_uri('/event/_blk_p1o0'))
      expect(second_page[:orderedItems][0][:id]).to eq(AuditEvent.activity_stream_uri('/event/_blk_p2o0'))
      expect(first_page[:orderedItems][0][:endTime]).to eq(first_timestamp.rfc3339)
      expect(second_page[:orderedItems][0][:endTime]).to eq(second_timestamp.rfc3339)
      expect(first_page[:orderedItems][0]['object'][:id]).to eq(AuditEvent.archivesspace_uri(top_container_1.uri))
      expect(second_page[:orderedItems][0]['object'][:id]).to eq(AuditEvent.archivesspace_uri(top_container_2.uri))
    end

    it 'intermingles bulk pages with regular audit pages in the overall stream' do
      top_container = create(:json_top_container)
      reset_audit_tables

      create_audit_event(:timestamp => Time.utc(2024, 1, 1, 10, 0, 0),
                         :activity_type => AuditEvent::ACTIVITY_TYPE_CREATE,
                         :records => [{:role => AuditEvent::ROLE_OBJECT,
                                       :type => 'resource',
                                       :uri => @resource.uri}])

      AuditPaginator.new.send(:paginate_audit_records)

      create_bulk_top_container_page(:timestamp => Time.utc(2024, 1, 1, 10, 30, 0),
                                     :top_container_ids => [top_container.id])

      create_audit_event(:timestamp => Time.utc(2024, 1, 1, 11, 0, 0),
                         :activity_type => AuditEvent::ACTIVITY_TYPE_UPDATE,
                         :records => [{:role => AuditEvent::ROLE_OBJECT,
                                       :type => 'accession',
                                       :uri => @accession.uri}])

      AuditPaginator.new.send(:paginate_audit_records)

      first_page = AuditEvent.page(1)
      second_page = AuditEvent.page(2)
      third_page = AuditEvent.page(3)

      expect(first_page[:next][:id]).to eq(AuditEvent.activity_stream_uri('/page/2'))
      expect(second_page[:prev][:id]).to eq(AuditEvent.activity_stream_uri('/page/1'))
      expect(second_page[:next][:id]).to eq(AuditEvent.activity_stream_uri('/page/3'))
      expect(third_page[:prev][:id]).to eq(AuditEvent.activity_stream_uri('/page/2'))
      expect(third_page).not_to have_key(:next)

      expect(first_page[:orderedItems][0][:id]).to match(%r{/activity-stream/event/\d+$})
      expect(second_page[:orderedItems][0][:id]).to eq(AuditEvent.activity_stream_uri('/event/_blk_p2o0'))
      expect(third_page[:orderedItems][0][:id]).to match(%r{/activity-stream/event/\d+$})

      expect(first_page[:orderedItems][0]['object'][:id]).to eq(AuditEvent.archivesspace_uri(@resource.uri))
      expect(second_page[:orderedItems][0]['object'][:id]).to eq(AuditEvent.archivesspace_uri(top_container.uri))
      expect(third_page[:orderedItems][0]['object'][:id]).to eq(AuditEvent.archivesspace_uri(@accession.uri))
    end
  end

  it 'logs audit events using the request context actor and change method' do
    RequestContext.put(:current_username, 'audit_user')
    RequestContext.put(:change_method, AuditEvent::CHANGE_METHOD_FORM)

    expect {
      AuditEvent.log_event(AuditEvent::ACTIVITY_TYPE_CREATE,
                           {AuditEvent::ROLE_OBJECT => @resource.uri})
    }.to change {$testdb[:audit_event].count}.by(1)

    event = $testdb[:audit_event].order(Sequel.desc(:id)).first
    records = $testdb[:audit_record].where(:audit_event_id => event[:id]).all

    expect(event[:actor_name]).to eq('audit_user')
    expect(event[:change_method]).to eq(AuditEvent::CHANGE_METHOD_FORM)
    expect(records.length).to eq(1)
    expect(records[0][:role]).to eq(AuditEvent::ROLE_OBJECT)
    expect(records[0][:type]).to eq('resource')
    expect(records[0][:uri]).to eq(@resource.uri)
  end

  describe 'log_event guard branches' do
    it 'does not log when audit logging is disabled' do
      allow(AppConfig).to receive(:[]).and_call_original
      allow(AppConfig).to receive(:[]).with(:enable_audit_logging).and_return(false)
      allow(AppConfig).to receive(:[]).with(:audit_logging_include_object_types).and_return(['accession', 'assessment'])

      expect {
        AuditEvent.log_event(AuditEvent::ACTIVITY_TYPE_CREATE,
                             {AuditEvent::ROLE_OBJECT => @resource.uri},
                             :actor => 'audit_user')
      }.not_to change {$testdb[:audit_event].count}
    end

    it 'does not log when there are no affected records' do
      expect {
        AuditEvent.log_event(AuditEvent::ACTIVITY_TYPE_CREATE,
                             {AuditEvent::ROLE_OBJECT => []},
                             :actor => 'audit_user')
      }.not_to change {$testdb[:audit_event].count}
    end

    it 'warns and returns for unsupported activity types' do
      allow(Log).to receive(:warn)

      expect {
        AuditEvent.log_event(999,
                             {AuditEvent::ROLE_OBJECT => @resource.uri},
                             :actor => 'audit_user')
      }.not_to change {$testdb[:audit_event].count}

      expect(Log).to have_received(:warn).with('Failed to log Audit Event - unsupported Activity Type: 999')
    end

    it 'warns and returns when no actor is available' do
      RequestContext.put(:current_username, nil)
      allow(Log).to receive(:warn)

      expect {
        AuditEvent.log_event(AuditEvent::ACTIVITY_TYPE_CREATE,
                             {AuditEvent::ROLE_OBJECT => @resource.uri})
      }.not_to change {$testdb[:audit_event].count}

      expect(Log).to have_received(:warn).with('Failed to log Audit Event - no Actor provided and no current username')
    end

    it 'skips invalid records while still logging supported ones' do
      allow(Log).to receive(:warn)
      allow(Log).to receive(:debug)

      allow(AppConfig).to receive(:[]).and_call_original
      allow(AppConfig).to receive(:[]).with(:enable_audit_logging).and_return(true)
      allow(AppConfig).to receive(:[]).with(:audit_logging_include_object_types).and_return(['accession', 'assessment'])

      expect {
        AuditEvent.log_event(AuditEvent::ACTIVITY_TYPE_UPDATE,
                             {AuditEvent::ROLE_OBJECT => ['not-a-uri', '/users/1', @resource.uri]},
                             :actor => 'audit_user')
      }.to change {$testdb[:audit_event].count}.by(1)

      event = $testdb[:audit_event].order(Sequel.desc(:id)).first
      records = $testdb[:audit_record].where(:audit_event_id => event[:id]).all

      expect(records.length).to eq(1)
      expect(records[0][:role]).to eq(AuditEvent::ROLE_OBJECT)
      expect(records[0][:type]).to eq('resource')
      expect(records[0][:uri]).to eq(@resource.uri)
      expect(Log).to have_received(:warn).with('Failed to log Audit Event Record - failed to parse URI: not-a-uri')
      expect(Log).to have_received(:debug).with('Skipping Audit Record - unsupported Object Type: user')
    end

    it 'does not log when every parsed record is discarded' do
      allow(Log).to receive(:warn)
      allow(Log).to receive(:debug)

      allow(AppConfig).to receive(:[]).and_call_original
      allow(AppConfig).to receive(:[]).with(:enable_audit_logging).and_return(true)
      allow(AppConfig).to receive(:[]).with(:audit_logging_include_object_types).and_return(['accession', 'assessment'])

      expect {
        AuditEvent.log_event(AuditEvent::ACTIVITY_TYPE_UPDATE,
                             {AuditEvent::ROLE_OBJECT => ['not-a-uri', '/users/1']},
                             :actor => 'audit_user')
      }.not_to change {$testdb[:audit_event].count}

      expect(Log).to have_received(:warn).with('Failed to log Audit Event Record - failed to parse URI: not-a-uri')
      expect(Log).to have_received(:debug).with('Skipping Audit Record - unsupported Object Type: user')
    end
  end

  describe 'change method entry paths' do
    it 'defaults to API when no explicit change method is present' do
      RequestContext.put(:change_method, nil)

      before_count = $testdb[:audit_event].where(:change_method => AuditEvent::CHANGE_METHOD_API).count

      AuditEvent.log_event(AuditEvent::ACTIVITY_TYPE_CREATE,
                           {AuditEvent::ROLE_OBJECT => @resource.uri})

      after_count = $testdb[:audit_event].where(:change_method => AuditEvent::CHANGE_METHOD_API).count

      expect(after_count).to eq(before_count + 1)
    end

    it 'records MIGRATION via the migration audit logger' do
      before_count = $testdb[:audit_event].where(:change_method => AuditEvent::CHANGE_METHOD_MIGRATION).count

      AuditEventLogger.new($testdb).log_update_event(AuditEvent::OBJECT_TYPE_RESOURCE, @resource.uri)

      event = $testdb[:audit_event].order(Sequel.desc(:id)).first

      expect($testdb[:audit_event].where(:change_method => AuditEvent::CHANGE_METHOD_MIGRATION).count).to eq(before_count + 1)
      expect(event[:change_method]).to eq(AuditEvent::CHANGE_METHOD_MIGRATION)
    end
  end

  describe 'ASModel_crud log_event' do
    it 'logs create events from create_from_json' do
      audit_calls = capture_log_event_calls

      accession = Accession.create_from_json(build(:json_accession), :repo_id => $repo_id)

      call = audit_calls.find do |audit_call|
        audit_call[:activity_type] == AuditEvent::ACTIVITY_TYPE_CREATE &&
          audit_call[:records] == {
            AuditEvent::ROLE_OBJECT => JSONModel(:accession).uri_for(accession.id, :repo_id => $repo_id)
          }
      end

      expect(call).not_to be_nil
    end

    it 'logs update events from update_from_json' do
      accession = create(:json_accession)
      audit_calls = capture_log_event_calls

      json = Accession.to_jsonmodel(accession.id)
      json.title = 'Updated accession title'

      Accession[accession.id].update_from_json(json)

      call = audit_calls.find do |audit_call|
        audit_call[:activity_type] == AuditEvent::ACTIVITY_TYPE_UPDATE &&
          audit_call[:records] == {AuditEvent::ROLE_OBJECT => accession.uri}
      end

      expect(call).not_to be_nil
    end

    it 'logs delete events from delete' do
      accession = create(:json_accession)
      audit_calls = capture_log_event_calls

      Accession[accession.id].delete

      expect(audit_calls.length).to eq(1)
      expect(audit_calls[0][:activity_type]).to eq(AuditEvent::ACTIVITY_TYPE_DELETE)
      expect(audit_calls[0][:records]).to eq(AuditEvent::ROLE_OBJECT => accession.uri)
    end
  end

  describe 'TreeNodes log_event' do
    it 'logs reorder updates from set_position_in_list' do
      resource = create(:json_resource)
      ao_1 = create(:json_archival_object, :dates => [], :resource => {:ref => resource.uri}, :title => 'AO1')
      create(:json_archival_object, :dates => [], :resource => {:ref => resource.uri}, :title => 'AO2')
      ao_3 = create(:json_archival_object, :dates => [], :resource => {:ref => resource.uri}, :title => 'AO3')

      audit_calls = capture_log_event_calls

      ArchivalObject[ao_1.id].set_position_in_list(1)

      expect(audit_calls.length).to eq(1)
      expect(audit_calls[0][:activity_type]).to eq(AuditEvent::ACTIVITY_TYPE_UPDATE)
      expect(audit_calls[0][:change_method]).to eq(AuditEvent::CHANGE_METHOD_REORDER)
      expect(audit_calls[0][:records].keys).to eq([AuditEvent::ROLE_OBJECT])
      expect(audit_calls[0][:records][AuditEvent::ROLE_OBJECT]).to contain_exactly(ao_1.uri, ao_3.uri)
    end
  end

  describe 'Relationships log_event' do
    it 'logs move events from assimilate' do
      merge_destination = create(:json_subject)
      merge_candidate = create(:json_subject)
      audit_calls = capture_log_event_calls

      Subject[merge_destination.id].assimilate([Subject[merge_candidate.id]])

      call = audit_calls.find do |audit_call|
        audit_call[:activity_type] == AuditEvent::ACTIVITY_TYPE_MOVE
      end

      expect(call).not_to be_nil
      expect(call[:records][AuditEvent::ROLE_OBJECT]).to contain_exactly(merge_destination.uri, merge_candidate.uri)
      expect(call[:records][AuditEvent::ROLE_TARGET]).to eq(merge_destination.uri)
    end
  end

  describe 'TopContainer log_event' do
    it 'logs batch updates through log_audit_event_for_batch' do
      top_container = create(:json_top_container)
      audit_calls = capture_log_event_calls

      TopContainer.log_audit_event_for_batch([top_container.id])

      expect(audit_calls.length).to eq(1)
      expect(audit_calls[0][:activity_type]).to eq(AuditEvent::ACTIVITY_TYPE_UPDATE)
      expect(audit_calls[0][:change_method]).to eq(AuditEvent::CHANGE_METHOD_MANAGE_TOP_CONTAINERS)
      expect(audit_calls[0][:records]).to eq(AuditEvent::ROLE_OBJECT => [top_container.uri])
    end
  end
end
