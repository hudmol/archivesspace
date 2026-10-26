require 'spec_helper'

describe 'AuditEvent controller' do

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

  def enable_audit_logging
    allow(AppConfig).to receive(:[]).and_call_original
    allow(AppConfig).to receive(:[]).with(:enable_audit_logging).and_return(true)
  end

  before(:each) do
    enable_audit_logging
    @resource = create(:json_resource)
    @accession = create(:json_accession)
  end

  it 'returns activity stream metadata for a specific object type' do
    AuditPaginator.new.send(:paginate_audit_records)

    pre_response = as_test_user('admin') do
      get '/activity-stream/resource'
      expect(last_response).to be_ok
      ASUtils.json_parse(last_response.body)
    end

    create_audit_event(:timestamp => Time.utc(2024, 1, 1, 10, 0, 0),
                       :activity_type => AuditEvent::ACTIVITY_TYPE_CREATE,
                       :records => [{:role => AuditEvent::ROLE_OBJECT,
                                     :type => 'resource',
                                     :uri => @resource.uri}])

    create_audit_event(:timestamp => Time.utc(2024, 1, 1, 10, 5, 0),
                       :activity_type => AuditEvent::ACTIVITY_TYPE_CREATE,
                       :records => [{:role => AuditEvent::ROLE_OBJECT,
                                     :type => 'accession',
                                     :uri => @accession.uri}])

    AuditPaginator.new.send(:paginate_audit_records)

    post_response = as_test_user('admin') do
      get '/activity-stream/resource'
      expect(last_response).to be_ok
      ASUtils.json_parse(last_response.body)
    end

    new_page = (pre_response['totalItems'] + 1) / AuditPaginator::PAGE_SIZE

    expect(post_response['type']).to eq('OrderedCollection')
    expect(post_response['totalItems']).to eq(pre_response['totalItems'] + 1)
    expect(post_response['first']).to eq(pre_response['first'])
    expect(post_response['last']['id']).to eq(AuditEvent.activity_stream_uri("/resource/page/#{new_page + 1}"))
  end

  describe 'change method entry paths' do
    it 'records FORM via the Rack request header path' do
      before_count = $testdb[:audit_event].where(:change_method => AuditEvent::CHANGE_METHOD_FORM).count

      post "/repositories/#{$repo_id}/resources",
           build(:json_resource).to_json,
           {
             'CONTENT_TYPE' => 'application/json',
             'HTTP_X_ARCHIVESSPACE_CHANGE_METHOD' => AuditEvent::CHANGE_METHOD_FORM.to_s
           }

      expect(last_response).to be_ok
      after_count = $testdb[:audit_event].where(:change_method => AuditEvent::CHANGE_METHOD_FORM).count

      expect(after_count).to eq(before_count + 1)
    end

    it 'records API via the component add children endpoint by default' do
      resource = create(:json_resource)

      archival_object = build(:json_archival_object, :dates => [])
      children = JSONModel(:archival_record_children).from_hash({
                                                                  'children' => [archival_object]
                                                                })

      before_count = $testdb[:audit_event].where(:change_method => AuditEvent::CHANGE_METHOD_API).count

      post "#{resource.uri}/children",
           children.to_json,
           {
             'CONTENT_TYPE' => 'application/json',
           }

      expect(last_response).to be_ok
      expect($testdb[:audit_event].where(:change_method => AuditEvent::CHANGE_METHOD_API).count).to eq(before_count + 1)
    end

    it 'records RAPID via the component add children endpoint from frontend client' do
      resource = create(:json_resource)

      archival_object = build(:json_archival_object, :dates => [])
      children = JSONModel(:archival_record_children).from_hash({
        'children' => [archival_object]
      })

      before_count = $testdb[:audit_event].where(:change_method => AuditEvent::CHANGE_METHOD_RAPID).count

      post "#{resource.uri}/children",
           children.to_json,
           {
             'CONTENT_TYPE' => 'application/json',
             'HTTP_X_ARCHIVESSPACE_CHANGE_METHOD' => AuditEvent::CHANGE_METHOD_FORM.to_s
           }

      expect(last_response).to be_ok
      expect($testdb[:audit_event].where(:change_method => AuditEvent::CHANGE_METHOD_RAPID).count).to eq(before_count + 1)
    end
  end
end
