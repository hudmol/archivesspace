{
  :schema => {
    "$schema" => "http://www.archivesspace.org/archivesspace.json",
    "version" => 1,
    "type" => "object",
    "uri" => "/activity-stream-export",
    "properties" => {
      "uri" => {"type" => "string", "required" => false},
      "export_type" => { "type" => "string" },
      "status" => { "type" => "string" },
      "criteria" => { "type" => "JSONModel(:activity_stream_export_criteria) object" },
    }
  }
}
