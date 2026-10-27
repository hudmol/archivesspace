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

    allow(AuditPaginator).to receive(:refresh_page_lock!)
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

  describe 'conditional page requests' do
    before(:each) do
      AuditPaginator.new.send(:paginate_audit_records)

      # Only complete pages with a successor get a stable ETag
      pages = $testdb[:audit_page].filter(page_filter: 'resource')
      pages.filter(page_number: 1).update(is_page_complete: 1)
      page = pages.filter(page_number: 1).first
      $testdb[:audit_page].insert(page.merge(page_number: 2, is_page_complete: 0).reject {|k, _| k == :id})
    end

    it 'sends no stable validators for a page without a successor' do
      $testdb[:audit_page].filter(page_filter: 'resource', page_number: 2).delete

      response = get_page

      expect(response.status).to eq(200)
      expect(response.headers['Last-Modified']).to be_nil
      expect(get_page('HTTP_IF_NONE_MATCH' => response.headers['ETag']).status).to eq(200)
    end

    def get_page(headers = {})
      as_test_user('admin') do
        get '/activity-stream/resource/page/1', {}, headers
        last_response
      end
    end

    it 'sends a weak, quoted ETag and a Last-Modified date' do
      response = get_page

      expect(response.status).to eq(200)
      expect(response.headers['ETag']).to match(/\AW\/"[0-9a-f]+"\z/)
      expect(response.headers['Last-Modified']).not_to be_nil
      expect(response.headers['Vary']).to include('Accept-Encoding')
    end

    it 'returns a bodiless 304 when If-None-Match matches' do
      etag = get_page.headers['ETag']

      response = get_page('HTTP_IF_NONE_MATCH' => "\"other\", #{etag}")

      expect(response.status).to eq(304)
      expect(response.body).to be_empty
      expect(response.headers['ETag']).to eq(etag)
    end

    it 'returns 200 when If-None-Match does not match' do
      expect(get_page('HTTP_IF_NONE_MATCH' => 'W/"other"').status).to eq(200)
    end

    it 'returns 304 when If-Modified-Since is not older than the page' do
      last_modified = get_page.headers['Last-Modified']

      expect(get_page('HTTP_IF_MODIFIED_SINCE' => last_modified).status).to eq(304)
      expect(get_page('HTTP_IF_MODIFIED_SINCE' => Time.at(0).httpdate).status).to eq(200)
    end

    it 'gzips the page when the client accepts it' do
      response = get_page('HTTP_ACCEPT_ENCODING' => 'gzip')

      expect(response.status).to eq(200)
      expect(response.headers['Content-Encoding']).to eq('gzip')
      expect(ASUtils.json_parse(Zlib.gunzip(response.body))['type']).to eq('OrderedCollectionPage')
    end
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
