require_relative 'moma_finding_aid_templates/finding_aid_helpers'

class MOMAFindingAidIndexer

  include JSONModel

  def self.get_indexer
    new(AppConfig[:backend_url])
  end

  def initialize(backend_url = nil)
    @client = ASpaceIndexerClient.new(backend_url)
    @time_to_sleep = AppConfig[:solr_indexing_frequency_seconds].to_i

    @indexer_name = 'MOMAFindingAidIndexer'
    @state = AppConfig[:index_state_class].constantize.new("moma_findingaid_indexer_state")
    @window_seconds = 30

    @renderer = Renderer.new(File.join(__dir__, 'moma_finding_aid_templates'))
  end


  def run
    while true
      begin
        run_index_round unless @client.paused?
      rescue Exception => e
        @client.reset_session
        Log.error("MOMAFindingAidIndexer caught an error: #{e.inspect}")
        Log.error(e.backtrace.join("\n"))
      end

      sleep @time_to_sleep
    end
  end

  private

  INDEXED_RECORD_TYPES = [:resource, :archival_object]

  class ASpaceIndexerClient < IndexerCommon; end

  def run_index_round
    @client.login

    start = Time.now

    # Apply adds/updates
    JSONModel(:repository).all.each do |repository|
      JSONModel.set_repository(repository.id)

      collections_processed = Set.new

      INDEXED_RECORD_TYPES.each do |record_type|
        modified_since = [@state.get_last_mtime(repository.id, record_type) - @window_seconds, 0].max

        all_ids = JSONModel::HTTP.get_json(JSONModel(record_type).uri_for, :all_ids => true, :modified_since => modified_since)

        updates_since_last_commit = 0
        total_update_count = 0

        lock = Mutex.new
        work_queue = all_ids.each_slice(250).to_a.reverse
        thread_count = 4
        worker_error = nil

        thread_count.times.map do |thread_id|
          session = JSONModel::HTTP.current_backend_session

          Thread.new do
            begin
              JSONModel.set_repository(repository.id)
              JSONModel::HTTP.current_backend_session = session

              loop do
                ids = lock.synchronize { work_queue.pop }
                break if ids.nil?

                records = JSONModel(record_type).all(:id_set => ids.join(","), 'resolve[]' => @client.resolved_attributes)
                records.each do |record|
                  if !repository.publish
                    # Treat the record as unpublished if its repository is.
                    record.publish = false
                  end

                  collection_uri = extract_collection_uri(record)
                  index_record_as_fragment(record, collection_uri)

                  lock.synchronize do
                    collections_processed << collection_uri
                  end
                end

                lock.synchronize do
                  updates_since_last_commit += ids.length
                  total_update_count += ids.length

                  if updates_since_last_commit >= 1000
                    log("Indexed %d of %d %s finding aid fragments" % [total_update_count, all_ids.length, record_type])
                    @client.send_commit
                    updates_since_last_commit = 0
                  end
                end
              end
            rescue Exception => e
              Log.error(e.backtrace.join("\n"))
              Log.error(e.inspect)

              lock.synchronize do
                worker_error = e
              end

              raise e
            end
          end
        end.each do |thread|
          thread.join rescue nil
        end

        raise worker_error if worker_error

        if total_update_count > 0
          log("Indexed %d of %d %s finding aid fragments" % [total_update_count, all_ids.length, record_type])
          @client.send_commit
        end
      end

      if generate_finding_aids(collections_processed, repository.publish)
        INDEXED_RECORD_TYPES.each do |record_type|
          @state.set_last_mtime(repository.id, record_type, start)
        end
      end
    end

    # Apply any deleted resources
    begin
      last_mtime = @state.get_last_mtime('_deletes', 'deletes')
      did_something = false

      page = 1
      while true
        deletes = JSONModel::HTTP.get_json("/delete-feed", :modified_since => [last_mtime - @window_seconds, 0].max, :page => page, :page_size => 200)

        deletes['results'].each do |deleted_uri|
          if deleted_uri =~ /resources/
            did_something = true

            solr_update(delete: {
                          query: "{!terms f=moma_findingaid_collection}" + deleted_uri,
                        })
          end
        end

        break if deletes['last_page'] <= page
        page += 1
      end

      if did_something
        @client.send_commit
      end

      @state.set_last_mtime('_deletes', 'deletes', start)
    end

    log("Index round completed in #{((Time.now.to_f - start.to_f) * 1000).to_i} milliseconds")
  end

  def extract_collection_uri(aspace_record)
    if aspace_record.jsonmodel_type == 'resource'
      aspace_record.uri
    elsif aspace_record.jsonmodel_type == 'archival_object'
      aspace_record.resource.fetch('ref')
    else
      raise log("Unknown record type: #{aspace_record.jsonmodel_type}")
    end
  end

  def clean_for_mapping(json)
    drop_unpublished!(
      keys_to_strings(json)
    )
  end

  def keys_to_strings(json)
    if json.is_a?(Hash)
      json.map {|k, v| [k.to_s, keys_to_strings(v)]}.to_h
    elsif json.is_a?(Array)
      json.map {|e| keys_to_strings(e)}
    else
      json
    end
  end

  def unpublished?(v)
    v.is_a?(Hash) && (v['publish'] == false || v.dig('_resolved', 'publish') == false)
  end

  def drop_unpublished!(json)
    if json.is_a?(Hash)
      json.delete_if { |_k, v| unpublished?(v) }
      json.each_value { |v| drop_unpublished!(v) }
    elsif json.is_a?(Array)
      json.reject! { |e| unpublished?(e) }
      json.each { |e| drop_unpublished!(e) }
    end
    json
  end

  def index_record_as_fragment(aspace_record, collection_uri)
    update = {}

    if aspace_record.publish
      json = clean_for_mapping(aspace_record.to_hash(:trusted))

      html = if aspace_record.jsonmodel_type == 'resource'
        @renderer.render_resource(json)
      elsif aspace_record.jsonmodel_type == 'archival_object'
        @renderer.render_archival_object(json)
      else
        raise log("Don't know how to render a record of type: #{aspace_record.jsonmodel_type}")
      end

      # display_string = aspace_record.jsonmodel_type == 'resource' ? aspace_record.title : aspace_record.display_string
      #
      # html = "<h1>" + display_string + "</h1>"

      update[:add] = {
        doc: {
          :id => build_solr_id(aspace_record.jsonmodel_type, aspace_record.id),
          :moma_findingaid_doctype => 'fragment',
          :moma_findingaid_html => compress(html),
          :moma_findingaid_collection => collection_uri
        }
      }
    else
      update[:delete] = {
        query: "{!terms f=id}" + build_solr_id(aspace_record.jsonmodel_type, aspace_record.id),
      }
    end

    solr_update(update)
  end

  def solr_update(update_spec)
    url = @client.solr_url
    url.path += '/update'
    url.query = 'commit=false'

    req = Net::HTTP::Post.new(url)
    req['Content-Type'] = 'application/json'
    req.body = ASUtils.to_json(update_spec)

    response = @client.do_http_request(url, req)

    if response.code != '200'
      raise log("Unexpected response from solr (code=#{response.code}): #{response.body}")
    end

    response
  end

  def compress(s)
    bytes = java.io.ByteArrayOutputStream.new
    gzip = java.util.zip.GZIPOutputStream.new(bytes)
    gzip.write(s.to_java_bytes)
    gzip.close

    java.util.Base64.getEncoder.encodeToString(bytes.toByteArray)
  end

  def decompress(s)
    bytes = java.util.Base64.getDecoder.decode(s)
    gzip = java.util.zip.GZIPInputStream.new(java.io.ByteArrayInputStream.new(bytes))
    out = java.io.ByteArrayOutputStream.new

    begin
      buf = Java::byte[8192].new

      while (len = gzip.read(buf, 0, buf.length)) != -1
        out.write(buf, 0, len)
      end
    ensure
      gzip.close
    end

    String.from_java_bytes(out.toByteArray).force_encoding('UTF-8')
  end

  def compress_stream
    tempfile = Tempfile.new('moma_finding_aid')
    gzip = nil

    begin
      gzip = java.util.zip.GZIPOutputStream.new(java.io.BufferedOutputStream.new(java.io.FileOutputStream.new(tempfile.path)))

      writer = Object.new

      writer.define_singleton_method(:<<) do |s|
        gzip.write(s.to_s.to_java_bytes)
      end

      yield writer

      gzip.close
      gzip = nil

      java.util.Base64.getEncoder.encodeToString(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(tempfile.path)))
    ensure
      begin
        gzip.close if gzip
      rescue
      end

      tempfile.close
      tempfile.unlink
    end
  end

  def decompress_stream(base64_compressed_data)
    bytes = java.util.Base64.getDecoder.decode(base64_compressed_data)
    gzip = java.util.zip.GZIPInputStream.new(java.io.ByteArrayInputStream.new(bytes))
    reader = java.io.BufferedReader.new(java.io.InputStreamReader.new(gzip, java.nio.charset.StandardCharsets::UTF_8))

    begin
      buf = Java::char[8192].new

      while (len = reader.read(buf, 0, buf.length)) != -1
        yield java.lang.String.new(buf, 0, len).to_s
      end
    ensure
      begin
        reader.close
      rescue
      end
    end
  end


  def generate_finding_aids(collection_uris_to_generate, repository_is_published)
    all_successful = true

    collection_uris_to_generate.each do |collection_uri|
      found_all_fragments = true

      ordered = if repository_is_published
                  JSONModel::HTTP.get_json(collection_uri + "/ordered_records")
                else
                  # Fake response to treat everything as unpublished
                  {'uris' => []}
                end

      collection_id = JSONModel.parse_reference(collection_uri).fetch(:id)

      # Unpublished/suppressed collection record will do this
      if ordered.fetch('uris').empty?
        solr_update(delete: {
                      query: "{!terms f=moma_findingaid_collection}" + collection_uri,
                    })

        @client.send_commit

        next
      end

      fragment_solr_ids = Set.new

      log("Building finding aid for collection #{collection_id}: " + ordered.fetch('uris').fetch(0).fetch('display_string'))

      compressed_full_finding_aid = compress_stream do |writer|
        ordered.fetch('uris').each_slice(16) do |ref_group|
          solr_ids = ref_group.map {|ref_obj|
            parsed = JSONModel.parse_reference(ref_obj.fetch('ref'))
            build_solr_id(parsed.fetch(:type), parsed.fetch(:id))
          }

          solr_ids.each do |solr_id|
            fragment_solr_ids << solr_id
          end

          compressed_fragments = {}
          fetch_solr_docs_by_field('id', solr_ids).each do |doc|
            compressed_fragments[doc.fetch('id')] = doc.fetch('moma_findingaid_html')
          end

          ref_group.each do |ref_obj|
            parsed = JSONModel.parse_reference(ref_obj.fetch('ref'))
            record_id = build_solr_id(parsed.fetch(:type), parsed.fetch(:id))

            if (fragment = compressed_fragments.fetch(record_id, nil))
              writer << decompress(fragment)
            else
              log("Failure finding a fragment: #{record_id}")
              found_all_fragments = false
            end
          end
        end
      end

      if found_all_fragments
        findingaid_id = build_solr_id('findingaid', collection_id)
        solr_update(add: {
                      doc: {
                        :id => findingaid_id,
                        :moma_findingaid_doctype => 'findingaid',
                        :moma_findingaid_html => compressed_full_finding_aid,
                        :moma_findingaid_collection => collection_uri
                      }
                    })

        @client.send_commit
      else
        log("Skipped build of finding aid because not all fragments were ready (#{collection_id}: " + ordered.fetch('uris').fetch(0).fetch('display_string') + ")")
        all_successful = false
      end

      # Locate any fragments that are no longer used by this collection
      needs_commit = false
      fetch_solr_docs_by_field('moma_findingaid_collection', [collection_uri], {
                                 rows: 2 ** 31 - 1,
                                 return_fields: ['id', 'moma_findingaid_doctype']})
        .each do |doc|
        next unless doc.fetch('moma_findingaid_doctype') == 'fragment'

        fragment_id = doc.fetch('id')
        unless fragment_solr_ids.include?(fragment_id)
          log("Dropping abandoned fragment: #{fragment_id} for collection #{collection_uri}")

          needs_commit = true
          solr_update(delete: {
                        query: "{!terms f=id}" + fragment_id,
                      })
        end
      end

      if needs_commit
        @client.send_commit
      end

    end

    all_successful
  end

  def build_solr_id(record_type, id, lock_version = nil)
    base_id = "findingaid_#{record_type}_#{id}"

    if lock_version
      "#{base_id}_#{lock_version}"
    else
      base_id
    end
  end

  def fetch_solr_docs_by_field(field, field_values, opts = {})
    url = @client.solr_url
    url.path += '/select'
    url.query = URI.encode_www_form(:q => "{!terms f=#{field}}" + field_values.join(','),
                                    :rows => opts.fetch(:rows, field_values.length),
                                    :defType => 'lucene',
                                    :fl => opts.fetch(:return_fields, '*'))

    response = @client.do_http_request(url, Net::HTTP::Get.new(url))

    if response.code == '200'
      ASUtils.json_parse(response.body).fetch('response').fetch('docs')
    else
      raise log("Unexpected response from solr (code=#{response.code}): #{response.body}")
    end
  end

  def log(line)
    msg = "#{@indexer_name} [#{Time.now}] #{line}"
    Log.info(msg)
    msg
  end

  class Renderer
    include FindingAid::Helpers

    def initialize(dir)
      @dir = dir

      @resource_erb = ERB.new(File.read(File.join(@dir, 'resource.html.erb')),
                              trim_mode: '-')

      @archival_object_erb = ERB.new(File.read(File.join(@dir, 'archival_object.html.erb')),
                              trim_mode: '-')
    end

    def render_resource(record)
      @resource_erb.result(binding)
    end

    def render_archival_object(record)
      @archival_object_erb.result(binding)
    end
  end


end
