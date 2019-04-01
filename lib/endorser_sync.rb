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
  # ENDORSER_SHEET_ID = ENV['GOOGLE_ENDORSER_SHEET_ID']
  ENDORSER_SHEET_ID = ENV['GOOGLE_ENDORSER_SHEET_COPY_ID']
  # Ready for Web
  READY_FOR_WEB_DATA_RANGE = 'Ready for Web!A2:AH'.freeze
  READY_FOR_WEB_HEADING_RANGE = 'Ready for Web!A1:AH1'.freeze
  READY_FOR_WEB_UPDATE_RANGE = "'Ready for Web'!AH%i:AH%i".freeze
  READY_FOR_WEB_COLUMN_HEADINGS = ['Submitted Date','Completion Time','Completion Status',"I'm Endorsing As...",'First Name ','Last Name','Title','Email',
     'Phone','Organization Name','Organization Name','Website URL','Address Line 1','Address Line 1','Address Line 2','City','State',
     'Postal Code','Organization Type','# of U.S. employees','Population','Comments (not required)','Please confirm','Response Url','Referrer',
     'Ip Address','Unprotected File List','Reviewer','Status','Notes','Featured Endorser', 'Final Staff Check', 'Link to Resource' 'Added to GET']
  
  # Revision Tab
  REVISION_DATA_RANGE = 'Revision: 131!A2:AE'.freeze
  REVISION_HEADING_RANGE = 'Revision: 131!A1:AE1'.freeze
  REVISION_UPDATE_RANGE = "'Revision: 131'!AE%i:AE%i".freeze
  REVISION_COLUMN_HEADINGS = ['Submitted Date', 'Completion Time', 'Completion Status', "I'm Endorsing As...", 'First Name', 'Last Name', 'Job Title',
    'Email', 'Phone', 'Organization Name', 'Organization Name', 'Website URL', 'Address Line 1', 'Address Line 1', 'Address Line 2',
    'City', 'State', 'Postal Code', 'Organization Type', '# of U.S. employees', 'Population', 'Comments (not required)',
    'Please confirm', 'Response Url', 'Referrer', 'Ip Address', 'Unprotected File List', 'Reviewer', 'Status', 'Notes', 'Added to GET']
  

  WP_ENDORSER_TABLE = 'bill_endorsers'

  FINAL_STAFF_CHECK = 31
  RESPONSE_URL = 23

  attr_accessor :google_client
  attr_accessor :token
  attr_accessor :wp_client
  attr_accessor :sf

  def initialize(use_production: false)
    @token = OauthToken.google_service_token(access: :read_write)
    @google_client = initialize_google_client(@token)
    @wp_client = use_production ? MysqlConnection.endorse_production_connection : MysqlConnection.endorse_staging_connection
    @sf = SalesforceSync.new
  end

  # Do I 'guess' endorsers who aren't tied?
  def sync_endorsers_to_get
    return unless valid_data_columns?

    # get rows that can be tied to GET
    version_endorsers = get_revision_data.select(&method(:include_revision_row_in_get?))
    web_endorsers = get_ready_for_web_data.select(&method(:include_ready_for_web_in_get?))

    sf_endorsers = get_linked_sf_endorsers
    by_fa_id = sf_endorsers.index_by(&:Form_Assembly_Reference_Id__c)

    # keep track of ready_for_web updates.. we don't update revision rows if they've been moved to ready for web
    updated_fa_ids = []
    sheet_updates = []

    web_endorsers.each_with_index do |endorser, i|
      fa_id = endorser[RESPONSE_URL].to_s.split('/')&.last
      
      if(by_fa_id.has_key?(fa_id))
        sf_row = by_fa_id[fa_id]
        updated_fa_ids << fa_id
        sheet_updates << {range: READY_FOR_WEB_UPDATE_RANGE % [i + 2, i + 2], values: [[sf_row.Id.to_s]]}
      end
    end

    version_endorsers.each_with_index do |endorser, i|
      fa_id = endorser[RESPONSE_URL].to_s.split('/')&.last
      binding.pry if i > 479
      if(by_fa_id.has_key?(fa_id) && updated_fa_ids.exclude?(fa_id))
        sf_row = by_fa_id[fa_id]
        sheet_updates << {range: REVISION_UPDATE_RANGE % [i + 2, i + 2], values: [[sf_row.Id.to_s]]}
      end
    end

    batch_update_values = Google::Apis::SheetsV4::BatchUpdateValuesRequest.new(data: sheet_updates, value_input_option: 'USER_ENTERED')
    binding.pry
    res = google_client.batch_update_values(ENDORSER_SHEET_ID, batch_update_values)

    if res.total_updated_rows != sheet_updates.size
      LOG.error("Total updated rows did not equal update: #{sheet_updates.to_json}")
      binding.pry
    end
    # TODO: old rows will not be synced only ones where FA ID is set in GET
  end

  def sync_endorsers_to_wordpress
    return unless valid_data_columns?

    current_endorsers = get_ready_for_web_data.select(&method(:include_row_in_wp?)).map(&method(:endorser_row))
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


  def include_row_in_wp?(row)
    row[31].to_s.strip.casecmp('x').zero?
  end

  def include_ready_for_web_in_get?(row)
    row[33].to_s.strip.empty?
  end

  def include_revision_row_in_get?(row)
    #29 - Added to get #27 - Status
    # Only if verified? Only if not added to GET?
    row[30].to_s.strip.length < 2 && (row[28].to_s.strip.casecmp('Verified').zero? || row[28].to_s.strip.casecmp('Declined').zero?)
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

  def get_ready_for_web_data
    google_client.get_spreadsheet_values(ENDORSER_SHEET_ID, READY_FOR_WEB_DATA_RANGE).values
  end

  def get_revision_data
    google_client.get_spreadsheet_values(ENDORSER_SHEET_ID, REVISION_DATA_RANGE).values
  end

  # column headings must match and be in the same order to ensure sync works correctly
  def valid_data_columns?
    if column_headings_ready_for_web != READY_FOR_WEB_COLUMN_HEADINGS || column_headings_revision != REVISION_COLUMN_HEADINGS
      LOG.error('Endorser spreadsheet columns have been re-arranged or modified. Unable to sync')
    end

    true
  end

  def column_headings_ready_for_web
    google_client.get_spreadsheet_values(ENDORSER_SHEET_ID, READY_FOR_WEB_HEADING_RANGE)&.values&.first
  end

  def column_headings_revision
    google_client.get_spreadsheet_values(ENDORSER_SHEET_ID, REVISION_HEADING_RANGE)&.values&.first
  end

  def get_sf_endorsers_json
   endorsers = get_sf_endorsers.to_a.map do |endorser|
      {name: endorser.Org_Ind_Name__c, type: endorser.Endorser_Type__c, state: endorser.State_Province__r&.Abbreviation__c.to_s, 
         zip: endorser.Zip_Postal_Code__c, district: endorser.EndorsementOrg__r&.Congressional_District__r&.Name.to_s}
   end

   File.open(ENDORSER_JSON, 'w'){|f| f.puts endorsers.to_json}
  end

  # NOTE: right now I'm only grabbing linked endorsements (ones that have Form_Assembly_Reference_Id__c)
  def get_linked_sf_endorsers
    supporters = sf.client.query(<<-QUERY)
      SELECT Id, Form_Assembly_Reference_Id__c, City__c, Date__c, EndorsementOrg__r.Name, Endorser_Type__c, Org_Ind_Name__c, State_Province__r.Name, 
        State_Province__r.Abbreviation__c, Zip_Postal_Code__c, EndorsementOrg__r.Congressional_District__c,
        EndorsementOrg__r.Congressional_District__r.Name
      FROM Endorsement__c
      WHERE Endorsement_Type__c INCLUDES ('Energy Innovation and Carbon Dividend Act') AND Private_From_Endorser__c = 'Public' 
        AND Country__c = 'United States' AND Endorsement_Status__c = 'Signed' 
        AND (State_Province__r.Abbreviation__c <> null OR EndorsementOrg__r.Congressional_District__r.Name <> null) 
        AND Form_Assembly_Reference_Id__c <> null
    QUERY
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