require 'google/apis/sheets_v4'
require 'googleauth'
require 'json'
require 'active_support/all'
require_relative '../web_sync/oauth_token'
require 'pry'

# Interact with Google API
class SwcResourceMap
  APPLICATION_NAME = ENV['GOOGLE_APP_NAME']
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'swc_resource_map.log'))
  TRAINING_SITEMAP_JSON = File.join(File.dirname(__FILE__), '..', '..', 'data', 'training_site_map.json')
  RESOURCE_SITEMAP_JSON = File.join(File.dirname(__FILE__), '..', '..', 'data', 'resource_site_map.json')
  SITEMAP_FILE = File.join(File.dirname(__FILE__), '..', '..', 'data', 'site_map.html')
  LINK_MATCH = /\/(resources|topics).*$/
  RESOURCE_MAP_SHEET_ID = ENV['GOOGLE_SWC_RESOURCE_SHEET_ID']
  TRAINING_MAP_DATA_RANGE = 'Examples!A2:H'.freeze
  RESOURCE_MAP_DATA_RANGE = 'ResourceCategories!A2:C'.freeze
  ORPHAN_MAP_DATA_RANGE = 'Orphans!A2:B'.freeze

  TOPIC_ROW = 0
  TRAINING_ROW = 1
  TOPIC_TRAINING_URL = 3
  RESOURCE_ROW = 4
  RESOURCE_URL = 5
  CATEGORY = 7

  attr_accessor :google_client
  attr_accessor :token
  attr_accessor :site_map

  def initialize
    @token = OauthToken.google_service_token
    @google_client = initialize_google_client(@token)
  end

  # TRAINING SITEMAP
  def write_training_sitemap
    training_site_map = build_training_sitemap
    File.open(TRAINING_SITEMAP_JSON, 'w'){|f| f.puts(training_site_map.to_json)}

    resource_nav = "<div class='training_nav ui-helper-hidden'>"
    training_string = training_site_map.reduce(resource_nav) do |str, (category, topics)|
      str += "<div id='#{section_class(category)}_accordion' class='nav_category #{section_class(category)} ui-helper-hidden'>"
      str += "<div class='nav_category_label'>#{category}</div>"
      topics.each do |topic, topic_data|
        str += "<div class='nav_category_topic topic_#{section_class(topic)}' data-training-ur='#{topic_data[:url]}'>"
        str += "<button class='btn btn-link topic-toggle collapsed' aria-expanded='true' data-target='##{section_class(topic)}' data-toggle='collapse'>#{topic}</button>"
        str += "<div id='#{section_class(topic)}' class='collapse' data-parent='##{section_class(category)}_accordion'>"
        topic_data[:training].each{|training| str += "<div class='training_link'><a href='#{training[:url]}' target='_blank'>#{training[:name]}</a></div>" }
        str += '</div>'
        str += '</div>'
      end
      str += '</div>'
    end
    training_string += '</div>'
    
    resource_site_map = build_resource_sitemap
    File.open(RESOURCE_SITEMAP_JSON, 'w'){|f| f.puts(resource_site_map.to_json)}
    
    training_string += "<div id='resource_accordion' class='resource_nav ui-helper-hidden'>"
    site_string = resource_site_map.reduce(training_string) do |str, (category, pages)|
      str += "<div class='resource_link'>"
      str += "<button class='btn btn-link topic-toggle collapsed' aria-expanded='true' data-target='##{section_class(category)}' data-toggle='collapse'>#{category}</button>"
      str += "<div id='#{section_class(category)}' class='collapse' data-parent='#resource_accordion'>"
      pages.each{|resource| str += "<div class='training_link'><a href='#{resource[:url]}' target='_blank'>#{resource[:name]}</a></div>" }
      str += '</div>'
      str += '</div>'
    end
    site_string += '</div>'

    File.open(SITEMAP_FILE, 'w'){|f| f.puts(site_string)}
  end

  # get sitemap as json
  def build_training_sitemap
    site_data = get_training_map_data.group_by{|row| row[CATEGORY]}
    # current_training = ""
    
    site_map = site_data.each_with_object({}) do |(current_category, rows), map|
      current_topic = ""
      map[current_category] = rows.each_with_object({}) do |row, map|
        if topic_row?(row)
          current_topic = row[TOPIC_ROW]
          map[current_topic] = {url: nav_link(row[TOPIC_TRAINING_URL]), training: [], resources: []}
        elsif training_row?(row)
          map[current_topic][:training] << {name: row[TRAINING_ROW], url: nav_link(row[TOPIC_TRAINING_URL])}
        end
      end
    end

    # add orphan data
    site_map['Other Training'] = {}
    site_map['Other Training']['Other Training'] = {url: '', training: [], resources: []}
    get_orphan_map_data.each do |row|
      next if row[1].to_s.exclude?('/')
      site_map['Other Training']['Other Training'][:training] << {name: row[0], url: nav_link(row[1])}
    end
    return site_map
  end

  # RESOURCE SITEMAP
  def build_resource_sitemap
    site_data = get_resource_map_data.group_by{|row| row[0]}
    
    site_map = site_data.each_with_object({}) do |(current_category, rows), map|
      map[current_category] = rows.each_with_object([]) do |row, resources|
        resources << {name: row[1], url: row[2]}
      end
    end
  end

  def nav_link(link)
    link.to_s.match(/\/(resources|topics).*$/)[0]
  end

  def section_class(section_name)
    section_name.to_s.downcase.gsub(' ', '_').gsub('&', 'and')
  end

  def topic_row?(row)
    row[TOPIC_ROW].present? && row[TOPIC_TRAINING_URL].present?
  end

  def training_row?(row)
    row[TRAINING_ROW].present? && row[TOPIC_TRAINING_URL].present?
  end

  def resource_row?(row)
    row[RESOURCE_ROW].present? && row[RESOURCE_URL].present?
  end

  def get_training_map_data
    google_client.get_spreadsheet_values(RESOURCE_MAP_SHEET_ID, TRAINING_MAP_DATA_RANGE).values
  end

  def get_resource_map_data
    google_client.get_spreadsheet_values(RESOURCE_MAP_SHEET_ID, RESOURCE_MAP_DATA_RANGE).values
  end

  def get_orphan_map_data
    google_client.get_spreadsheet_values(RESOURCE_MAP_SHEET_ID, ORPHAN_MAP_DATA_RANGE).values
  end

  private

  def initialize_google_client(token)
    service = Google::Apis::SheetsV4::SheetsService.new
    service.client_options.application_name = APPLICATION_NAME
    service.authorization = token
    service.key = ENV['GOOGLE_API_KEY']
    service
  end
end
