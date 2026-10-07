# frozen_string_literal: true

# Helpers shared by the Resource and Archival Object ERB templates.
#
# The templates are fed a single parsed ArchivesSpace JSON record (a Hash) plus
# these helpers. Everything here is pure and side-effect free so the same record
# always renders the same fragment.
#
# Two escaping worlds to keep straight:
#   * h(str)          -> plain text fields (author, id_0, dates ...). HTML-escaped.
#   * ead_inline(str) -> note/title CONTENT. This is already XML-escaped EAD, so
#                        it must NOT be re-escaped; we only translate the known
#                        EAD inline elements to HTML and drop anything unknown.

require 'cgi'

module FindingAid
  module Helpers
    module_function

    # --- escaping -----------------------------------------------------------

    # Escape a plain-text value for HTML output.
    def h(text)
      return '' if text.nil?

      CGI.escapeHTML(text.to_s)
    end

    # HTML tags we are willing to emit from EAD content. Anything else that
    # survives translation (stray EAD elements, etc.) is stripped.
    INLINE_ALLOWED = %w[cite strong em u b i br a span sup sub].freeze

    # Translate EAD inline markup (already XML-escaped) into HTML.
    def ead_inline(text)
      return '' if text.nil?

      s = text.to_s.dup

      # <lb/> -> line break
      s = s.gsub(%r{<lb\b[^>]*/?>}, '<br>')

      # <title ...>...</title> -> <cite> (film / book titles, etc.)
      s = s.gsub(%r{<title\b[^>]*>(.*?)</title>}m) { "<cite>#{Regexp.last_match(1)}</cite>" }

      # <emph render="..">..</emph>
      s = s.gsub(%r{<emph\b[^>]*\brender="([^"]*)"[^>]*>(.*?)</emph>}m) do
        open, close = emph_tags(Regexp.last_match(1))
        "#{open}#{Regexp.last_match(2)}#{close}"
      end
      # <emph> with no render attribute
      s = s.gsub(%r{<emph\b[^>]*>(.*?)</emph>}m) { "<em>#{Regexp.last_match(1)}</em>" }

      # Drop any remaining tag whose (namespace-stripped) name isn't allowed,
      # keeping its inner text. This clears <num>, <persname>, leftover EAD, etc.
      # Bind the MatchData first: computing `name` runs another regex (#sub),
      # which would otherwise clobber Regexp.last_match before we read m[0].
      s.gsub(%r{<(/?)([a-zA-Z][\w:.-]*)\b[^>]*?/?>}) do
        m = Regexp.last_match
        name = m[2].downcase.sub(/\A.*:/, '')
        INLINE_ALLOWED.include?(name) ? m[0] : ''
      end
    end

    def emph_tags(render)
      case render
      when 'bold'         then ['<strong>', '</strong>']
      when 'italic'       then ['<em>', '</em>']
      when 'underline'    then ['<u>', '</u>']
      when 'bolditalic'   then ['<strong><em>', '</em></strong>']
      when 'super'        then ['<sup>', '</sup>']
      when 'sub'          then ['<sub>', '</sub>']
      else ['<em>', '</em>']
      end
    end

    # --- block-level note content ------------------------------------------

    # A note_text content string -> one or more <p> blocks. Blank lines start a
    # new paragraph; single newlines become <br>. A CALS <table> is converted
    # to an HTML table instead of being paragraphed.
    def note_to_html(content)
      return '' if content.nil?

      c = content.to_s
      return cals_to_html(c) if c.strip.start_with?('<table')

      c.split(/\n[ \t]*\n/)
       .map(&:strip)
       .reject(&:empty?)
       .map { |para| "<p>#{ead_inline(para).gsub(/\n[ \t]*/, '<br>')}</p>" }
       .join("\n")
    end

    # Convert an EAD/CALS <table> (tgroup/row/entry) to a plain HTML table.
    # Regex-based on purpose: no XML dependency, good enough for finding aids.
    def cals_to_html(xml)
      thead = xml[%r{<thead\b[^>]*>(.*?)</thead>}m, 1]
      tbody = xml[%r{<tbody\b[^>]*>(.*?)</tbody>}m, 1]
      body_src = tbody || (thead ? xml.sub(%r{<thead\b[^>]*>.*?</thead>}m, '') : xml)

      out = +'<table class="ead-table">'
      out << "<thead>#{cals_rows(thead, 'th')}</thead>" if thead
      out << "<tbody>#{cals_rows(body_src, 'td')}</tbody>"
      out << '</table>'
      out
    end

    def cals_rows(chunk, cell)
      return '' if chunk.nil?

      chunk.scan(%r{<row\b[^>]*>(.*?)</row>}m).map do |row|
        cells = row[0].scan(%r{<entry\b[^>]*>(.*?)</entry>}m)
                      .map { |e| "<#{cell}>#{ead_inline(e[0].strip)}</#{cell}>" }
        "<tr>#{cells.join}</tr>"
      end.join
    end

    # --- notes --------------------------------------------------------------

    # Preferred reading order for notes; anything unlisted keeps its original
    # position after the known ones (stable).
    NOTE_ORDER = %w[
      abstract bioghist scopecontent arrangement
      accessrestrict userestrict phystech legalstatus
      relatedmaterial separatedmaterial
      custodhist acqinfo appraisal accruals altformavail originalsloc
      prefercite processinfo fileplan
      bibliography index odd otherfindaid dimensions
    ].freeze

    def ordered_notes(record)
      notes = (record['notes'] || []).reject { |n| n['publish'] == false }
      notes.each_with_index.sort_by do |note, i|
        idx = NOTE_ORDER.index(note['type'])
        [idx || NOTE_ORDER.length, i]
      end.map(&:first)
    end

    # Render a note's body (subnotes for multipart, content for singlepart).
    def render_note_body(note)
      out = +''
      if note['subnotes']
        note['subnotes'].each do |sn|
          next if sn['publish'] == false

          out << render_subnote(sn)
        end
      elsif note['content']
        Array(note['content']).each { |c| out << note_to_html(c) }
      end
      out
    end

    def render_subnote(sn)
      case sn['jsonmodel_type']
      when 'note_text'
        note_to_html(sn['content'])
      when 'note_orderedlist'
        items = Array(sn['items']).map { |it| "<li>#{ead_inline(it)}</li>" }.join
        %(<ol class="ead-list">#{items}</ol>)
      when 'note_definedlist'
        items = Array(sn['items']).map do |it|
          "<dt>#{ead_inline(it['label'])}</dt><dd>#{ead_inline(it['value'])}</dd>"
        end.join
        %(<dl class="ead-deflist">#{items}</dl>)
      else
        # Unknown subnote types (chronology, outline, ...) fall back to any text.
        sn['content'] ? Array(sn['content']).map { |c| note_to_html(c) }.join : ''
      end
    end

    # --- record accessors ---------------------------------------------------

    def display_title(record)
      ead_inline(record['title'] || record['display_string'] || '')
    end

    def unit_dates(record)
      Array(record['dates']).map do |d|
        d['expression'] || [d['begin'], d['end']].compact.join('–')
      end.reject { |x| x.nil? || x.empty? }.join(', ')
    end

    def extent_statement(record)
      Array(record['extents']).map do |e|
        [e['number'], e['extent_type']].compact.join(' ').strip
      end.reject(&:empty?).join('; ')
    end

    LANGUAGES = {
      'eng' => 'English', 'rus' => 'Russian', 'ger' => 'German',
      'fre' => 'French', 'spa' => 'Spanish', 'ita' => 'Italian'
    }.freeze

    # Prefer coded languages (language_and_script); fall back to langmaterial notes.
    def languages(record)
      coded = []
      noted = []
      Array(record['lang_materials']).each do |lm|
        if (ls = lm['language_and_script']) && ls['language']
          coded << (LANGUAGES[ls['language']] || ls['language'])
        end
        Array(lm['notes']).each do |n|
          Array(n['content']).each { |c| noted << c.to_s.strip }
        end
      end
      (coded.empty? ? noted : coded).reject(&:empty?).uniq
    end

    def linked_agents(record, role)
      Array(record['linked_agents']).select { |a| a['role'] == role }.map do |a|
        resolved = a['_resolved']
        (resolved && (resolved['title'] || resolved.dig('names', 0, 'sort_name'))) || a['ref']
      end
    end

    # Subject/agent headings that resolve to a readable label (needs ArchivesSpace
    # `resolve[]`). Refs with no resolved record are skipped.
    def index_terms(record, key)
      Array(record[key]).map { |t| t.dig('_resolved', 'title') }.compact
    end

    # --- archival object structure -----------------------------------------

    GROUPING_LEVELS = %w[
      collection recordgrp fonds series subseries subgrp subfonds subcollection
    ].freeze

    def grouping?(record)
      GROUPING_LEVELS.include?(record['level'])
    end

    def depth(record)
      Array(record['ancestors']).length
    end

    # The container indicator shown in the id column of an item row (e.g. "A.0*").
    def container_id(record)
      inst = Array(record['instances']).find { |i| i['sub_container'] }
      return '' unless inst

      sc = inst['sub_container']
      sc['indicator_3'] || sc['indicator_2'] || sc['indicator'] || ''
    end
  end
end
