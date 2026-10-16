{
  :schema => {
    "$schema" => "http://www.archivesspace.org/archivesspace.json",
    "version" => 1,
    "type" => "object",
    "properties" => {
      "from_date" => { "type" => "string", "minLength" => 1, "ifmissing" => "error"},
      "to_date" => { "type" => "string", "minLength" => 1, "ifmissing" => "error"},

      "user" => {
        "type" => "object",
        "subtype" => "ref",
        "properties" => {
          "ref" => {
            "type" => "JSONModel(:user) uri",
            "ifmissing" => "error"
          },
          "_resolved" => {
            "type" => "object",
            "readonly" => "true"
          }
        }
      },

      "resource" => {
        "type" => "object",
        "subtype" => "ref",
        "properties" => {
          "ref" => {
            "type" => "JSONModel(:resource) uri",
            "ifmissing" => "error"
          },
          "_resolved" => {
            "type" => "object",
            "readonly" => "true"
          }
        }
      },

      "repository" => {
        "type" => "object",
        "subtype" => "ref",
        "properties" => {
          "ref" => {
            "type" => "JSONModel(:repository) uri",
            "ifmissing" => "error"
          },
          "_resolved" => {
            "type" => "object",
            "readonly" => "true"
          }
        }
      },

      "object_type" => { "type" => "array", "items" => { "type" => "string" } },
      "activity_type" => { "type" => "array", "items" => { "type" => "string" } },
      "change_method" => { "type" => "array", "items" => { "type" => "string" } },
    }
  }
}
