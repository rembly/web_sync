# frozen_string_literal: true

require 'rest-client'
require 'json'
require 'zip'
require 'active_support/all'
require 'csv'
require 'pry'
require_relative '../web_sync/json_web_token'
require_relative '../salesforce_sync'
require_relative '../web_sync/throttled_api_client'


# Looks in the /data/import directory for the the most recently exported group setting 
# file from https://community.citizensclimate.org/admin/groups and creates an identical
# zip file with a groups.json file that's had its group_map attribute updated with a 
# current mapping of SWC groups to Salesforce groups.
#
# For example exported ccllobby_groups_1563645864.zip will generate a new zip file 
# groups_1563645864
#
# Note that this is required vs. just adding new mappings because groups that have gone 
# private (because they've went from active to in progress for example) will throw errors
# if a mapping is used that includes them.
class SwcGroupMapping
  IMPORT_DIR = File.join(File.dirname(__FILE__), '..', '..', 'data', 'import')
  SWC_SF_GROUP_MAP_MISSING = File.join(File.dirname(__FILE__), '..', '..', 'data', 'swc_sf_group_map_missing.json')
  LOG_FILE = File.join(File.dirname(__FILE__), '..', '..', 'log', 'swc_group_mapping.log')
  LOG = Logger.new(LOG_FILE)

  attr_accessor :sf
  attr_accessor :api

  def initialize
    @sf = SalesforceSync.new
    @swc_token = JsonWebToken.swc_token
    @api = ThrottledApiClient.new(api_url: "https://#{ENV['SWC_AUDIENCE']}/services/4.0/",
      logger: LOG, token_method: JsonWebToken.method(:swc_token))
  end

  def generate_group_mapping
    # look for most recent zip file of group page
    group_files = Dir.glob("#{IMPORT_DIR}/cclobby_groups_*.zip")
    zip_file = group_files.sort_by{|f| File.mtime(f)}&.last
    timestamp = zip_file.to_s.match(/groups_(\d*)\./)[1]

    Zip::File.open(zip_file) do |zip_file|
      # should only be one file called groups.json
      contents = zip_file.first.get_input_stream.read
      contents_json = JSON.parse(contents)
      group_map = get_swc_sf_group_map
      # update the exported group settings to have the latest group mapping
      contents_json['group_map'] = group_map

      # save both the new file itself as well as a zip file that will be used for uploading to swc
      File.open("#{IMPORT_DIR}/groups_#{timestamp}.json", 'w'){|f| f.puts(contents_json.to_json)}
      Zip::File.open("#{IMPORT_DIR}/groups_#{timestamp}.zip", Zip::File::CREATE) do |zipfile|
        zipfile.add('groups.json', "#{IMPORT_DIR}/groups_#{timestamp}.json")
      end
    end

  end

  # builds the mapping of SWC group to SF group for import in the SWC group admin page
  def get_swc_sf_group_map
    groups = sf.client.query('SELECT Id, SWC_Group_ID__c, Name FROM Group__c WHERE SWC_Group_ID__c <> null')
    swc_group_ids = api.call(endpoint: 'groups').map{|grp| grp['id']}.uniq
    group_map = groups.select{|g| swc_group_ids.include?(g.SWC_Group_ID__c.to_i.to_s)}
                      .map{ |g| { 'swl_group': g.SWC_Group_ID__c.to_i.to_s, 'thirdparty_group': g.Name } }
    missing_groups = groups.select{|g| swc_group_ids.exclude?(g.SWC_Group_ID__c.to_i.to_s) }
                      .map{ |g| { 'swl_group': g.SWC_Group_ID__c.to_i.to_s, 'thirdparty_group': g.Name } }
    
    File.open(SWC_SF_GROUP_MAP_MISSING, 'w') do |f|
      f.puts(missing_groups.to_json)
    end
    return group_map
  end

end
