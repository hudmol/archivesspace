#!/usr/bin/env ruby

# Demo driver: render the sample resource + archival objects through the two ERB
# templates and stitch the fragments into one standalone finding-aid page.
#
#   ruby build.rb            # writes example_output.html
#
# In a real pipeline you would render each record wherever you have it and
# concatenate the fragments in tree order; this script just wires up the samples.

require 'json'
require 'erb'
require_relative 'finding_aid_helpers'
require 'net/http'

# Render context: exposes `record` and the helper methods to a template's binding.
class Renderer
  include FindingAid::Helpers

  def initialize(dir)
    @dir = dir
  end

  def render(template, record)
    @record = record
    path = File.join(@dir, template)
    ERB.new(File.read(path), trim_mode: '-').result(binding)
  end

  # Available to templates as the local-looking `record`.
  attr_reader :record
end

class ArchivesSpace

  def initialize(backend_url, username, password)
    @url = backend_url

    r = Net::HTTP.post_form(URI.join(@url, "/users/#{username}/login"),
                       :password => password)


    @session = JSON.parse(r.body).fetch('session')
  end

  def get_json(path)
    uri = URI.join(@url, path)
    request = Net::HTTP::Get.new(uri)
    request["X-ArchivesSpace-Session"] = @session

    response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
      http.request(request)
    end

    JSON.parse(response.body)
  end
end


INCONSIDERATELY_HARDCODED_REPO_ID = 2
INCONSIDERATELY_HARDCODED_BACKEND_URL = "http://localhost:4567"
INCONSIDERATELY_HARDCODED_USERNAME = "admin"
INCONSIDERATELY_HARDCODED_PASSWORD = "admin"

include FindingAid::Helpers

def main
  output_path = File.absolute_path(File.join(__dir__, '../public/public'))

  unless Dir.exist?(output_path)
    raise "Couldn't find an output path: #{output_path}"
  end

  client = ArchivesSpace.new(INCONSIDERATELY_HARDCODED_BACKEND_URL, INCONSIDERATELY_HARDCODED_USERNAME, INCONSIDERATELY_HARDCODED_PASSWORD)
  renderer = Renderer.new(__dir__)

  resource_ids = client.get_json("/repositories/#{INCONSIDERATELY_HARDCODED_REPO_ID}/resources?all_ids=true").shuffle

  resource_ids.each do |resource_id|
    $stderr.puts("* Processing resource #{resource_id}")

    resource = client.get_json("/repositories/#{INCONSIDERATELY_HARDCODED_REPO_ID}/resources/#{resource_id}")

    fragments = ''
    fragments << renderer.render('resource.html.erb', resource)

    ao_ids = client.get_json("/repositories/#{INCONSIDERATELY_HARDCODED_REPO_ID}/resources/#{resource_id}/ordered_records").fetch('uris')

    has_digital_object_map = {}

    ao_ids.each_slice(32) do |subset|
      uri_subset = subset.map {|ao| ao.fetch('ref')}

      uri_subset.map {|ao_ref| Thread.new { client.get_json("#{ao_ref}?resolve[]=digital_object&resolve[]=linked_agents") }}.each do |result|
        if digital_instances?(result.value)
          has_digital_object_map[result.value['uri']] = true
          Array(result.value['ancestors']).each do |ancestor|
            has_digital_object_map[ancestor['ref']] = true
          end
        end
      end
    end

    $stderr.puts("** Resource #{resource_id} contains #{ao_ids.length} Archival Objects")

    ao_ids.each_slice(32) do |subset|
      uri_subset = subset.map {|ao| ao.fetch('ref')}

      uri_subset.map {|ao_ref| Thread.new { client.get_json("#{ao_ref}?resolve[]=digital_object&resolve[]=linked_agents") }}.each do |result|
        result.value['has_digital_object'] = has_digital_object_map.fetch(result.value['uri'], false)
        fragments << renderer.render('archival_object.html.erb', result.value)
      end
    end

    page = <<~HTML
  <!doctype html>
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{FindingAid::Helpers.h(resource['title'])}</title>
  </head>
  <body>
  <div class="finding-aid-wrapper">
  <section class="finding-aid-nav">
    <div><label><input type="checkbox" id="toggle-do" /> Show Only Digital Material</label></div>
    <div class="finding-aid-nav-inner"></div>
  </section>
    <main class="finding-aid">
  #{fragments}
    </main>

</div>

<script>
window.addEventListener('DOMContentLoaded', function() {
  const applyHashHighlight = () => {
    if (window.location.hash) {
      var id = window.location.hash.substring(1);
      var el = document.getElementById(id);
      if (el) {
        el.classList.add('highlight');
        el.scrollIntoView();
      }
    }
  }

  applyHashHighlight();

  window.addEventListener('hashchange', function() {
    document.querySelectorAll('.highlight').forEach(function(el) {
      el.classList.remove('highlight');
    });
    applyHashHighlight();
  });


  const nav = document.querySelector('.finding-aid-nav-inner');

  document.querySelectorAll('.finding-aid-wrapper section').forEach(section => {
    const heading = section.querySelector('h1, h2, h3, h4, h5, h6');
    if (!heading) {
      return;
    }
    const level = parseInt(heading.tagName.substring(1), 10);

    const link = document.createElement('a');

    if (!section.id) {
      section.id = 'gensec_' + Math.trunc(Math.random() * 1000000);
    } else {
      link.classList.add('moma-lh-nav-item');
    }

    link.href = '#' + section.id;
    link.textContent = heading.textContent.trim();
    link.style.display = 'block';
    link.style.marginLeft = (level - 1) + 'em';

    if (section.classList.contains('moma-has-do')) {
      link.classList.add('moma-has-do');
    }
    nav.appendChild(link);
  });

});

</script>

<div class="back-to-top">
  <button>Back to top</button>
</div>

<script>
  document.querySelector('.back-to-top').addEventListener('click', () => {
    window.scrollTo({ top: 0, behavior: 'instant' });
    const nav = document.querySelector('.finding-aid-nav');
    if (nav) {
      nav.scrollTo({ top: 0, behavior: 'instant' });
    }
  });

  document.querySelector('#toggle-do').addEventListener('change', (event) => {
    const showOnlyDigital = event.target.checked;
    document.body.classList.toggle('show-only-digital', showOnlyDigital);
  });
</script>

<style>
body.show-only-digital .moma-item,
body.show-only-digital .moma-lh-nav-item {
  display: none !important;
}
body.show-only-digital .moma-item.moma-has-do,
body.show-only-digital .moma-lh-nav-item.moma-has-do {
  display: block !important;
}
</style>

  </body>
  </html>
HTML

    out = File.join(output_path, resource.fetch('uri').gsub('/', '_') + '.html')
    File.write(out, page)
    puts "Wrote #{out} (#{page.bytesize} bytes)"
  end
end


main
