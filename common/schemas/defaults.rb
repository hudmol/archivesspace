browse_column_enums = {
  'accession' => [
    'title', 'identifier', 'accession_date', 'acquisition_type', 'resource_type',
    'restrictions_apply', 'publish', 'access_restrictions', 'use_restrictions',
    'dates', 'extents', 'processing_priority', 'processors'
  ],
  'resource' => [
    'title', 'identifier', 'level', 'resource_type', 'language', 'publish',
    'restrictions', 'dates', 'extents', 'ead_id', 'finding_aid_status',
    'processing_priority', 'processors'
  ],
  'archival_object' => [
    "title", "publish", "context", "component_id", "ref_id", "level", 'dates',
    'extents', 'language'
  ],
  'digital_object' => [
    'title', 'digital_object_id', 'publish', 'level', 'digital_object_type', 'language',
    'restrictions', 'dates', 'extents'
  ],
  'digital_object_component' => [
    "title", "publish", "context", 'dates', 'extents', 'language'
  ],
  'subjects' => [
    "title", "publish", "source", "first_term_type"
  ],
  'agent' => [
    "title", "primary_type", "publish", "authority_id", "source", "rules", "is_user"
  ],
  'location' => [
    "title", "publish", "building", "floor", "room", "area", "location_holdings",
    "location_profile_display_string_u_ssort", 'temporary'
  ],
  'event' => [
    "agents", "event_type", "outcome", "linked_records"
  ],
  'collection_management' => [
    "parent_title", "parent_type", "processing_priority", "processing_status", "processing_hours_total",
    "processing_funding_source", "processors"
  ],
  'classification' => [
    "title", "publish", "has_classification_terms"
  ],
  'top_container' => [
    "title", "publish", "container_profile_display_string_u_sstr", "location_display_string_u_sstr", "type",
    "indicator", "barcode", "context"
  ],
  'assessment' => [
    "assessment_id", "assessment_records", "assessment_record_types", "assessment_surveyors",
    "assessment_survey_begin", "assessment_review_required", "assessment_sensitive_material",
    "assessment_inactive", "assessment_survey_year", "assessment_collections",
    "assessment_completed", "assessment_formats", "assessment_ratings",
    "assessment_conservation_issues"
  ],
  'repositories' => [
    "title", "publish"
  ],
  'container_profile' => [
    "title", "publish", "container_profile_width_u_sstr", "container_profile_height_u_sstr",
    "container_profile_depth_u_sstr", "container_profile_dimension_units_u_sstr"
  ],
  'location_profile' => [
    "title", "publish", "location_profile_width_u_sstr", "location_profile_height_u_sstr",
    "location_profile_depth_u_sstr", "location_profile_dimension_units_u_sstr"
  ],
  'multi' => [
    "primary_type", "title", "context", "identifier", 'dates', 'extents'
  ]
}

solr_fields = begin
  ASUtils.json_parse(
    ASHTTP.get(URI.join(AppConfig[:solr_url], 'schema'))
    )['schema']['fields'].map { |field| [field['name'], field] }.to_h
rescue Errno::ECONNREFUSED
  nil
end 

browse_columns = {}
browse_column_enums.keys.each do |type|
  Array(1..AppConfig[:max_search_columns]).each do |i|
    browse_columns["#{type}_browse_column_#{i}"] = {
      "type" => "string",
      "enum" => browse_column_enums[type] + ['audit_info', 'no_value'],
      "required" => false
    }
  end
  browse_columns["#{type}_sort_column"] = {
      "type" => "string",
      "enum" => browse_column_enums[type].select{
        |c| !solr_fields || (solr_fields[c] && !solr_fields[c]['multiValued'])
        } + ['create_time', 'user_mtime', 'no_value'],
      "required" => false
    }
  browse_columns["#{type}_sort_direction"] = {
    "type" => "string",
    "enum" => ['asc', 'desc'],
    "required" => false
  }
end

{
  :schema => {
    "$schema" => "http://www.archivesspace.org/archivesspace.json",
    "version" => 1,
    "type" => "object",
    "properties" => {

      "show_suppressed" =>  {"type" => "boolean", "required" => false},
      "publish" =>  {"type" => "boolean", "required" => false},

      "default_values" => {
        "type" => "boolean",
        "required" => false,
        "default" => false
      },

      "note_order" => {
        "type" => "array",
        "items" => {"type" => "string"}
      }

    }.merge(browse_columns),
  },
}
