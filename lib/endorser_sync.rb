require 'google/apis/sheets_v4'
require 'googleauth'
require 'json'
require 'active_support/all'
require_relative 'web_sync/oauth_token'
require_relative 'web_sync/mysql_connection'
require_relative './salesforce_sync'
require 'pry'

# Interact with Google API

class EndorserSync
  APPLICATION_NAME = ENV['GOOGLE_APP_NAME']
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'sync_endorsers.log'))
  ENDORSER_JSON = File.join(File.dirname(__FILE__), '..', 'data', 'endorsers.json')
  ENDORSER_SHEET_ID = ENV['GOOGLE_ENDORSER_SHEET_ID']
  ENDORSER_DATA_RANGE = 'Ready for Web!A2:AG'.freeze
  COLUMN_HEADING_RANGE = 'Ready for Web!A1:AG1'.freeze
  COLUMN_HEADINGS = ['Submitted Date','Completion Time','Completion Status',"I'm Endorsing As...",'First Name ','Last Name','Title','Email',
     'Phone','Organization Name','Organization Name','Website URL','Address Line 1','Address Line 1','Address Line 2','City','State',
     'Postal Code','Organization Type','# of U.S. employees','Population','Comments (not required)','Please confirm','Response Url','Referrer',
     'Ip Address','Unprotected File List','Reviewer','Status','Notes','Featured Endorser', 'Final Staff Check', 'Link to Resource']
  WP_ENDORSER_TABLE = 'bill_endorsers'

  FINAL_STAFF_CHECK = 31

  attr_accessor :google_client
  attr_accessor :token
  attr_accessor :wp_client
  attr_accessor :sf

  def initialize
    @token = OauthToken.google_service_token
    @google_client = initialize_google_client(@token)
    # @wp_client = MysqlConnection.get_connection
    @wp_client = MysqlConnection.endorse_staging_connection
    @sf = SalesforceSync.new
  end

  def sync_endorsers
    return unless valid_data_columns?

    current_endorsers = get_current_endorser_data.select(&method(:include_row?)).map(&method(:endorser_row))
    clear_wp_endorsers
    
    begin
       wp_client.query(<<-INSERT)
          INSERT INTO #{WP_ENDORSER_TABLE}(first_name, last_name, title, organization_name,
             website_url, city, state, postal_code, organization_type, featured_endorser, individual_organization, link_to_resource)
          VALUES
             #{current_endorsers.map{|endorser_row| '("' + endorser_row.join('","') + '")'}.join(',')}
       INSERT
       
       LOG.info("Synchronized #{current_endorsers.size} endorsers to Wordpress")
    rescue Mysql2::Error => e
       LOG.error("Unable to synchronize endorsers to Wordpress: #{e.message}")
       LOG.error(e.backtrace.inspect)
    end
  end


  def include_row?(row)
    row[31].to_s.strip.casecmp('x').zero?
  end

  def endorser_row(row)
    is_org = row[3] == 'An organization'
    endorsing_as = row[3]
    org_type = row[18]
    first_name, last_name, title = row[4], row[5], row[6]
    org = row[9].present? ? row[9] : row[10]
    org_name = is_org ? org : '';
    website_url = row[11]
    city, state, zip = row[15], row[16], row[17]
    comments = row[21]
    linked_resource = row[32]
    # submitted_at = row[0]
    featured_endorser = row[30].to_s.present? ? 1 : 0;

    [first_name, last_name, title, org_name, website_url, city, state, zip, org_type, featured_endorser, org, linked_resource]
  end

  def clear_wp_endorsers
    wp_client.query("DELETE from #{WP_ENDORSER_TABLE}")
  end

  def get_vetted_endorsers
    get_current_endorser_data.select{|endorser_row| endorser_row[13].to_s.downcase.starts_with?('y')}
  end
  
  def get_current_endorser_data
    google_client.get_spreadsheet_values(ENDORSER_SHEET_ID, ENDORSER_DATA_RANGE).values
  end

  # column headings must match and be in the same order to ensure sync works correctly
  def valid_data_columns?
    if column_headings != COLUMN_HEADINGS
      LOG.error('Endorser spreadsheet columns have been re-arranged or modified. Unable to sync to Wordpress')
    end

    true
  end

  def column_headings
    google_client.get_spreadsheet_values(ENDORSER_SHEET_ID, COLUMN_HEADING_RANGE)&.values&.first
  end

  def get_sf_endorsers_json
   endorsers = get_sf_endorsers.to_a.map do |endorser|
      {name: endorser.Org_Ind_Name__c, type: endorser.Endorser_Type__c, state: endorser.State_Province__r&.Abbreviation__c.to_s, 
         zip: endorser.Zip_Postal_Code__c, district: endorser.EndorsementOrg__r&.Congressional_District__r&.Name.to_s}
   end

   File.open(ENDORSER_JSON, 'w'){|f| f.puts endorsers.to_json}
  end

  def get_sf_endorsers
    supporters = sf.client.query(<<-QUERY)
      SELECT City__c, Date__c, EndorsementOrg__r.Name, Endorser_Type__c, Org_Ind_Name__c, State_Province__r.Name, State_Province__r.Abbreviation__c, 
         Zip_Postal_Code__c, EndorsementOrg__r.Congressional_District__c, EndorsementOrg__r.Congressional_District__r.Name
      FROM Endorsement__c
      WHERE Endorsement_Type__c INCLUDES ('Energy Innovation and Carbon Dividend Act') AND Private_From_Endorser__c = 'Public'AND Country__c = 'United States' 
         AND Endorsement_Status__c = 'Signed' AND (State_Province__r.Abbreviation__c <> null OR EndorsementOrg__r.Congressional_District__r.Name <> null)
    QUERY
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