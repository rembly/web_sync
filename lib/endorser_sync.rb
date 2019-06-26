# frozen_string_literal: true

require 'google/apis/sheets_v4'
require 'googleauth'
require 'json'
require 'active_support/all'
require_relative './web_sync/email_notifier'
require_relative 'web_sync/oauth_token'
require_relative 'web_sync/mysql_connection'
require_relative './salesforce_sync'
require 'pry'

class EndorserSync
  EMAIL_NOTIFIER = EmailNotifier.new
  APPLICATION_NAME = ENV['GOOGLE_APP_NAME']
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'sync_endorsers.log'))
  ENDORSER_JSON = File.join(File.dirname(__FILE__), '..', 'data', 'endorsers.json')
  ENDORSER_SHEET_ID = ENV['GOOGLE_ENDORSER_SHEET_ID']
  # ENDORSER_SHEET_ID = ENV['GOOGLE_ENDORSER_SHEET_COPY_ID']
  # Ready for Web ** Update on Column Range
  READY_FOR_WEB_DATA_RANGE = 'Ready for Web!A2:AI'
  READY_FOR_WEB_HEADING_RANGE = 'Ready for Web!A1:AI1'
  READY_FOR_WEB_UPDATE_RANGE = "'Ready for Web'!AI%i:AI%i"
  READY_FOR_WEB_COLUMN_HEADINGS = ['Submitted Date', 'Completion Time', 'Completion Status', "I'm Endorsing As...", 'First Name ', 'Last Name', 'Title', 'Email',
                                   'Phone', 'Organization Name', 'Organization Name', 'Website URL', 'Address Line 1', 'Address Line 1', 'Address Line 2', 'City', 'State',
                                   'Postal Code', 'Organization Type', '# of U.S. employees', 'Population', 'Comments (not required)', 'Please confirm', 'Campaign', 'Response Url', 'Referrer',
                                   'Ip Address', 'Unprotected File List', 'Reviewer', 'Status', 'Notes', 'Featured Endorser', 'Final Staff Check', 'Link to Resource', 'Added to GET'].freeze

  # Revision Tab - The ranges are templated to work with all revision tabs
  REVISION_DATA_RANGE = 'Revision: %i!A2:AF'
  REVISION_HEADING_RANGE = 'Revision: %i!A1:AF1'
  REVISION_UPDATE_RANGE = "'Revision: %i'!AF%i:AF%i"
  REVISION_COLUMN_HEADINGS = ['Submitted Date', 'Completion Time', 'Completion Status', "I'm Endorsing As...", 'First Name ', 'Last Name', 'Job Title',
                              'Email', 'Phone', 'Organization Name', 'Organization Name', 'Website URL', 'Address Line 1', 'Address Line 1', 'Address Line 2',
                              'City', 'State', 'Postal Code', 'Organization Type', '# of U.S. employees', 'Population', 'Comments (not required)',
                              'Please confirm', 'Campaign', 'Response Url', 'Referrer', 'Ip Address', 'Unprotected File List', 'Reviewer', 'Status', 'Notes', 'Added to GET'].freeze

  WP_ENDORSER_TABLE = 'bill_endorsers'
  FINAL_STAFF_CHECK = 32
  READY_FOR_WEB_SF_COLUMN = 34
  REVISION_SF_COLUMN = 31
  RESPONSE_URL = 24
  STATUS_COL = 29
  LINKED_RESOURCE_COL = 33
  FEATURED_ENDORSER_COL = 31

  attr_accessor :google_client
  attr_accessor :token
  attr_accessor :wp_client
  attr_accessor :sf
  attr_accessor :revision_sheet_numbers

  def initialize(use_production: false)
    @token = OauthToken.google_service_token(access: :read_write)
    @google_client = initialize_google_client(@token)
    @wp_client = use_production ? MysqlConnection.endorse_production_connection : MysqlConnection.endorse_staging_connection
    @sf = SalesforceSync.new
  end

  # **** EndorserSync.new.sync_endorsers_to_get
  def sync_endorsers_to_get
    return unless valid_data_columns?

    # get rows that can be tied to GET
    web_endorsers = get_ready_for_web_data

    sf_endorsers = get_linked_sf_endorsers
    by_fa_id = sf_endorsers.index_by(&:Form_Assembly_Reference_Id__c)

    # keep track of ready_for_web updates.. we don't update revision rows if they've been moved to ready for web
    updated_fa_ids = []
    sheet_updates = []

    web_endorsers.each_with_index do |endorser, i|
      fa_id = endorser[RESPONSE_URL].to_s.split('/')&.last
      updated_fa_ids << fa_id

      next unless include_ready_for_web_in_get?(endorser) && by_fa_id.key?(fa_id)

      sf_row = by_fa_id[fa_id]
      updated = update_get(endorser, sf_row)
      in_progress = !completed_status?(endorser)
      sheet_updates << { range: format(READY_FOR_WEB_UPDATE_RANGE, i + 2, i + 2), values: [[in_progress ? 'in progress' : sf_row.Id.to_s]] }
    end

    get_revision_sheet_numbers.each do |revision_number|
      version_endorsers = get_revision_data(revision_number)
      version_endorsers.each_with_index do |endorser, i|
        fa_id = endorser[RESPONSE_URL].to_s.split('/')&.last

        if include_revision_row_in_get?(endorser) && by_fa_id.key?(fa_id)
          if updated_fa_ids.exclude?(fa_id)
            sf_row = by_fa_id[fa_id]
            updated = update_get(endorser, sf_row)
            in_progress = !completed_status?(endorser)
            sheet_updates << { range: format(REVISION_UPDATE_RANGE, revision_number, i + 2, i + 2), values: [[in_progress ? 'in progress' : sf_row.Id.to_s]] }
          else
            sheet_updates << { range: format(REVISION_UPDATE_RANGE, revision_number, i + 2, i + 2), values: [['Ready for Web']] }
          end
        end
      end
    end

    batch_update_values = Google::Apis::SheetsV4::BatchUpdateValuesRequest.new(data: sheet_updates, value_input_option: 'USER_ENTERED')
    res = google_client.batch_update_values(ENDORSER_SHEET_ID, batch_update_values)

    if res.total_updated_rows != sheet_updates.size
      LOG.error("Total updated rows did not equal update: #{sheet_updates.to_json}")
    end
  end

  # Compare the SF record vs the sheet record. If any fields are different, save those changes to the GET
  def update_get(row, sf_row)
    type = row[3]
    final_staff_check = row[FINAL_STAFF_CHECK].to_s.strip.casecmp('x').zero?
    # handle municipal????
    return unless ['A prominent individual', 'An organization'].include?(type)

    is_org = (type == 'An organization')

    street = [row[12].to_s.strip + row[13].to_s.strip, row[14].to_s.strip].map(&:strip).reject(&:empty?).join(', ')
    contact_name = "#{row[4].to_s.strip} #{row[5].to_s.strip}"
    name = is_org ? row[9].to_s.strip : contact_name
    status = row[STATUS_COL]
    # sf_end_status = final_staff_check ? 'Posted to Web' : %w[Declined Verified].include?(status) ? status : 'Pending'
    
    org_map = { Mailing_City__c: 15, Email__c: 7, Primary_Contact_Title__c: 6, Phone__c: 8, 
      Mailing_Zip_Postal_Code__c: 17, Endorsement_Campaign__c: 23 }
    end_type = is_org ? 'Organizational' : 'Individual'
    end_map = { City__c: 15, Zip_Postal_Code__c: 17, Contact_Email__c: 7, Contact_Phone__c: 8, Comments__c: 21, Endorsement_Campaign__c: 23 }
    
    # only update if a field changed
    sf_org = sf_row.EndorsementOrg__r
    org_changed = false
    org_map.each do |sf_field, row_index|
      sheet_val = row[row_index].to_s
      org_changed = set_if_different(sf_org, sf_field, sheet_val.to_s.strip) || org_changed
    end
    # non-auto fields
    org_changed = set_if_different(sf_org, :Endorser_Type__c, end_type) || org_changed
    org_changed = set_if_different(sf_org, :Name__c, name) || org_changed
    org_changed = set_if_different(sf_org, :Mailing_Street__c, street) || org_changed
    org_changed = set_if_different(sf_org, :Primary_Contact_Name__c, contact_name) || org_changed
    org_changed = set_if_different(sf_org, :Website__c, 'http://' + row[11]) || org_changed
    org_changed = set_if_different(sf_org, :Population__c, row[20].to_i.to_f) || org_changed if row[20].present?
    org_changed = set_if_different(sf_org, :Employees__c, row[19].to_i.to_f) || org_changed if row[19].present?
    
    if org_changed
      LOG.info("SF Endorser Org #{sf_org.Id} Changed: #{sf_org}")
      did_save = sf_org.save!
      unless did_save
        LOG.error("Failed to save: #{sf_org}")
        send_email("Failed to save: #{sf_org}")
      end
    end
    
    # update endorsement
    end_changed = false
    end_map.each do |sf_field, row_index|
      sheet_val = row[row_index].to_s
      end_changed = set_if_different(sf_row, sf_field, sheet_val.to_s.strip) || end_changed
    end
    contact_title = [row[6].to_s, row[10].to_s].map(&:strip).reject(&:empty?).join(', ')
    end_changed = set_if_different(sf_row, :Endorser_Type__c, end_type) || end_changed
    # end_changed = set_if_different(sf_row, :Verification_Status__c, sf_end_status) || end_changed
    end_changed = set_if_different(sf_row, :Address__c, street) || end_changed
    end_changed = set_if_different(sf_row, :Org_Ind_Name__c, name) || end_changed
    end_changed = set_if_different(sf_row, :Contact_Title__c, contact_title) || end_changed
    end_changed = set_if_different(sf_row, :Contact_Name__c, contact_name) || end_changed
    
    if end_changed
      LOG.info("SF Endorsement #{sf_row.Id} Changed: #{sf_row}")
      did_save = sf_row.save!
      unless did_save
        LOG.error("Failed to save: #{sf_row}")
        send_email("Failed to save: #{sf_row}")
      end
    end

    end_changed || org_changed
  end
  
  # this will determine if a field is different between the SF and Sheet records
  # returns true if a field was updated
  def set_if_different(sf_row, field, sheet_val)
    sf_val = sf_row.send(field)
    sheet_val = sheet_val.to_s.strip
    if sf_val.to_s != sheet_val
      LOG.info("ID: #{sf_row.Id} - SF Field #{field} updated from #{sf_val} to #{sheet_val} for #{sf_row}")
      sf_row.send(field.to_s + '=', sheet_val)
      return true
    end
    false
  end
  
  def sync_endorsers_to_wordpress
    return unless valid_data_columns?
    
    current_endorsers = get_ready_for_web_data.select(&method(:include_row_in_wp?)).map(&method(:endorser_row))
    # binding.pry if last_name == 'Chaplin'
    clear_wp_endorsers
    
    begin
      wp_client.query(<<-INSERT)
      INSERT INTO #{WP_ENDORSER_TABLE}(first_name, last_name, title, organization_name,
      website_url, city, state, postal_code, organization_type, featured_endorser, individual_organization, link_to_resource)
      VALUES
      #{current_endorsers.map { |endorser_row| '("' + endorser_row.join('","') + '")' }.join(',')}
      INSERT
      
      LOG.info("Synchronized #{current_endorsers.size} endorsers to Wordpress")
    rescue Mysql2::Error => e
      message = "Unable to synchronize endorsers to Wordpress: #{e.message}"
      LOG.error(message)
      send_email(message)
      LOG.error(e.backtrace.inspect)
    end
  end

  def include_row_in_wp?(row)
    row[FINAL_STAFF_CHECK].to_s.strip.casecmp('x').zero?
  end

  def include_ready_for_web_in_get?(row)
    row[READY_FOR_WEB_SF_COLUMN].to_s.strip.length != 18 || !completed_status?(row)
  end

  def include_revision_row_in_get?(row)
    row[REVISION_SF_COLUMN].to_s.strip.length != 18 || !completed_status?(row)
  end

  def completed_status?(endorser)
    endorser[STATUS_COL].to_s.strip.casecmp('Verified').zero? || endorser[STATUS_COL].to_s.strip.casecmp('Declined').zero?
  end

  def endorser_row(row)
    is_org = row[3] == 'An organization'
    endorsing_as = row[3]
    org_type = row[18]
    first_name = row[4]
    last_name = row[5]
    title = escape_sql(row[6])
    org = row[9].present? ? row[9] : row[10]
    org_name = is_org ? org : ''
    website_url = row[11]
    city = row[15]
    state = row[16]
    zip = row[17]
    comments = escape_sql(row[21])
    linked_resource = row[LINKED_RESOURCE_COL]
    # submitted_at = row[0]
    featured_endorser = row[FEATURED_ENDORSER_COL].to_s.casecmp('Featured').zero? ? 1 : 0
    
    # binding.pry if last_name == 'Chaplin'
    [first_name, last_name, title, escape_sql(org_name), website_url, city, state, zip, org_type, featured_endorser, org, linked_resource]
  end

  def escape_sql(str)
    str.to_s.gsub('"', "'")
  end

  def clear_wp_endorsers
    wp_client.query("DELETE from #{WP_ENDORSER_TABLE}")
  end

  def get_ready_for_web_data
    google_client.get_spreadsheet_values(ENDORSER_SHEET_ID, READY_FOR_WEB_DATA_RANGE).values
  end

  def get_revision_data(revision_number)
    google_client.get_spreadsheet_values(ENDORSER_SHEET_ID, REVISION_DATA_RANGE % revision_number).values
  end

  # column headings must match and be in the same order to ensure sync works correctly
  def valid_data_columns?
    revision_missmatch = get_revision_sheet_numbers.any? { |number| column_headings_revision(number) != REVISION_COLUMN_HEADINGS }

    if column_headings_ready_for_web != READY_FOR_WEB_COLUMN_HEADINGS || revision_missmatch
      message = 'Endorser spreadsheet columns have been re-arranged or modified. Unable to sync'
      LOG.error(message)
      send_email(message)
      return false
    end
    true
  end

  def column_headings_ready_for_web
    google_client.get_spreadsheet_values(ENDORSER_SHEET_ID, READY_FOR_WEB_HEADING_RANGE)&.values&.first
  end

  def column_headings_revision(revision_number)
    google_client.get_spreadsheet_values(ENDORSER_SHEET_ID, REVISION_HEADING_RANGE % revision_number)&.values&.first
  end

  def get_revision_sheet_numbers
    revision_regex = /Revision: (\d*)/
    @revision_sheet_numbers ||= google_client.get_spreadsheet(ENDORSER_SHEET_ID).sheets.map(&:properties).map(&:title)
                                             .map { |t| t.match(revision_regex)&.captures&.first }.compact
    @revision_sheet_numbers
  end

  def get_sf_endorsers_json
    endorsers = get_sf_endorsers.to_a.map do |endorser|
      { name: endorser.Org_Ind_Name__c, type: endorser.Endorser_Type__c, state: endorser.State_Province__r&.Abbreviation__c.to_s,
        zip: endorser.Zip_Postal_Code__c, district: endorser.EndorsementOrg__r&.Congressional_District__r&.Name.to_s }
    end

    File.open(ENDORSER_JSON, 'w') { |f| f.puts endorsers.to_json }
  end

  # NOTE: right now I'm only grabbing linked endorsements (ones that have Form_Assembly_Reference_Id__c)
  def get_linked_sf_endorsers
    supporters = sf.client.query(<<-QUERY)
      SELECT Id, Form_Assembly_Reference_Id__c, City__c, Date__c, Endorser_Type__c, Org_Ind_Name__c, State_Province__r.Name,
        State_Province__r.Abbreviation__c, Zip_Postal_Code__c, EndorsementOrg__r.Congressional_District__c,
        EndorsementOrg__r.Congressional_District__r.Name, EndorsementOrg__r.Population__c, EndorsementOrg__r.Employees__c,
        EndorsementOrg__r.Email__c, EndorsementOrg__r.Primary_Contact_Title__c, EndorsementOrg__r.Phone__c,
        Comments__c, Address__c, Contact_Email__c, Contact_Name__c, Contact_Phone__c, Contact_Title__c, EndorsementOrg__r.Website__c,
        EndorsementOrg__r.Mailing_Zip_Postal_Code__c, EndorsementOrg__r.Mailing_City__c, EndorsementOrg__r.Primary_Contact_Name__c,
        EndorsementOrg__r.Approval_Status__c, EndorsementOrg__r.Id, EndorsementOrg__r.Mailing_Street__c,
        EndorsementOrg__r.Endorser_Type__c, EndorsementOrg__r.Name__c, Verification_Status__c, Endorsement_Campaign__c,
        EndorsementOrg__r.Endorsement_Campaign__c
      FROM Endorsement__c
      WHERE Endorsement_Type__c INCLUDES ('Energy Innovation and Carbon Dividend Act') AND Private_From_Endorser__c = 'Public'
        AND Country__c = 'United States' AND Endorsement_Status__c = 'Signed'
        AND (State_Province__r.Abbreviation__c <> null OR EndorsementOrg__r.Congressional_District__r.Name <> null)
        AND Form_Assembly_Reference_Id__c <> null
    QUERY
  end

  def get_sf_endorsers
    supporters = sf.client.query(<<-QUERY)
      SELECT EndorsementOrg__r.Name, Endorser_Type__c, Org_Ind_Name__c, State_Province__r.Name, State_Province__r.Abbreviation__c,
         Zip_Postal_Code__c, EndorsementOrg__r.Congressional_District__c, EndorsementOrg__r.Congressional_District__r.Name
      FROM Endorsement__c
      WHERE Endorsement_Type__c INCLUDES ('Energy Innovation and Carbon Dividend Act') AND Private_From_Endorser__c = 'Public'AND Country__c = 'United States'
         AND Endorsement_Status__c = 'Signed' AND (State_Province__r.Abbreviation__c <> null OR EndorsementOrg__r.Congressional_District__r.Name <> null)
    QUERY
  end

  def send_email(message)
    to = 'bryan.hermsen@citizensclimate.org'
    EMAIL_NOTIFIER.send_email(subject: 'Endorser Sync Error', body: message, to: to)
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
