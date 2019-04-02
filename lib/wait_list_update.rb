require 'google/apis/sheets_v4'
require 'googleauth'
require 'json'
require 'active_support/all'
require_relative 'web_sync/oauth_token'
require_relative './salesforce_sync'
require 'pry'

class WaitListUpdate
  APPLICATION_NAME = ENV['GOOGLE_APP_NAME']
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'update_conference_waitlist.log'))
  # WAIT_LIST_SHEET_ID = ENV['CONFERENCE_WAIT_LIST_COPY_SHEET_ID']
  WAIT_LIST_SHEET_ID = ENV['CONFERENCE_WAIT_LIST_SHEET_ID']
  # ON COLUMN CHANGE
  WAIT_LIST_DATA_RANGE = "'Data 2019'!A2:Y308".freeze
  COLUMN_HEADING_RANGE = "'Data 2019'!A1:Y".freeze
  UPDATE_RANGE = "'Data 2019'!T%i:Y%i".freeze
  COLUMN_HEADINGS = ['Timestamp', 'Priority', 'Notes by MM/MP', 'MP part', 'First Name', 'Last Name', 'Email Address', 'MM Sent Email', 'Registered Lobby day?',
    'Phone Number', 'Amy 1 mtg', 'Congressional District', '# of Constituents Attending from CD', 'Are you under 18?',
    'Please add any additional information', 'Registered Conference only?', 'Do you have a chaperone?', 'Who is your chaperone?', 'Are they registered for the conference already?',
    'Group Leader', 'Primary Liaison', 'Other Liaison', 'Person of Color', 'Political Affiliation', 'SFID']

  SELECT_FIELDS = [*SalesforceSync::REQUIRED_FIELDS, *SalesforceSync::EMAIL_FIELDS, *SalesforceSync::PHONE_FIELDS,
    'Group_Leader_del__c',  'Primary_Liaison_Count__c',  'Backup_Liaison_Count__c', 'Race_Ethnicity__c', 'Political_Affiliation__c']

  SFID_CELL = 24
  EMAIL_CELL = 6
  MULTIPLE_MATCHES = :multiple_matches
  NO_MATCHES = :no_matches

  attr_accessor :google_client
  attr_accessor :token
  attr_accessor :sf

  def initialize
    @token = OauthToken.google_service_token(access: :read_write)
    @google_client = initialize_google_client(@token)
    @sf = SalesforceSync.new
  end

  def update_sheet
    return false unless valid_data_columns?

    sheet_data = get_data
    sf_list = []

    # process in groups of 10 so that we can query for SF records in batches
    sheet_data.values.select(&method(:row_to_update?)).each_slice(10) do |rows_to_update|
      sf_list.concat(get_sf_records(rows_to_update).to_a)
    end

    # we should have all SF records that we were able to match. Now run through and set fields
    update = sheet_data.values.each_with_object([]).with_index do |(row, arr), i|
      if row_to_update?(row)
        # TODO: ON COLUMN CHANGE
        values = row.slice(19..-1)
        sf_record = get_matching_sf_record(row, sf_list)
        if sf_record == NO_MATCHES || sf_record == MULTIPLE_MATCHES
          values[5] = 'No Match Found' if sf_record == NO_MATCHES
          values[5] = 'Duplicate SF Records Found' if sf_record == MULTIPLE_MATCHES
        else
          values[5] = sf_record.Id
          values[4] = sf_record.Political_Affiliation__c
          values[3] = sf_record.Race_Ethnicity__c.present? && (sf_record.Race_Ethnicity__c != 'White/Caucasian') ? 'TRUE' : 'FALSE'
          values[2] = sf_record.Backup_Liaison_Count__c.to_i > 0 ? 'TRUE' : 'FALSE'
          values[1] = sf_record.Primary_Liaison_Count__c.to_i > 0 ? 'TRUE' : 'FALSE'
          values[0] = sf_record.Group_Leader_del__c ? 'TRUE' : 'FALSE'
        end

        arr << {range: UPDATE_RANGE % [i + 2, i + 2], values: [values]}
      end
    end

    batch_update_values = Google::Apis::SheetsV4::BatchUpdateValuesRequest.new(data: update, value_input_option: 'USER_ENTERED')
    res = google_client.batch_update_values(WaitListUpdate::WAIT_LIST_SHEET_ID, batch_update_values)
    if res.total_updated_rows != update.size
      LOG.error("Total updated rows did not equal update: #{update.to_json}")
    end
  end

  def get_matching_sf_record(row, sf_list)
    matched_by_email = sf_list.select do |sf_user|
      SalesforceSync::EMAIL_FIELDS.map(&:to_sym).any?{|email_field| 
        sf_user.try(email_field).present? && sf_user.try(email_field) == row[EMAIL_CELL] 
      }
    end
    # if we have multiple matches match on name
    if matched_by_email.size > 1
      first, last, phone = row[4], row[5], row[9]
      matched_by_email.select{|sf_user| sf_user.FirstName == first && sf_user.LastName == last}
      if matched_by_email.size > 1
        LOG.error("Multiple matches found for #{row}: #{matched_by_email}")
        return MULTIPLE_MATCHES
      end
      return matched_by_email.first
    end
    matched_by_email.any? ? matched_by_email.first : NO_MATCHES
  end

  def get_sf_records(rows_to_update)
    # search for contact by email
    emails = rows_to_update.map { |contact| contact[EMAIL_CELL] }

    @sf.client.query(<<-QUERY)
      SELECT #{SELECT_FIELDS.join(', ')}
      FROM Contact
      WHERE #{sf.quoted_email_list(emails)}
    QUERY
  end

  def row_to_update?(row)
    row[0].present? && row[EMAIL_CELL].present? && row[SFID_CELL].blank?
  end
  
  def get_data
    google_client.get_spreadsheet_values(WAIT_LIST_SHEET_ID, WAIT_LIST_DATA_RANGE)
  end

  def column_headings
    google_client.get_spreadsheet_values(WAIT_LIST_SHEET_ID, COLUMN_HEADING_RANGE)&.values&.first.map(&:strip)
  end

  def valid_data_columns?
    if column_headings != COLUMN_HEADINGS
      LOG.error('Wait List spreadsheet columns have been re-arranged or modified. Unable to sync')
      return false
    end
    true
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
