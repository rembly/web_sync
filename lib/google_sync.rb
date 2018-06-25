require 'google/apis/sheets_v4'
require 'googleauth'
require 'json'
require 'active_support/all'
require_relative 'web_sync/oauth_token'
require_relative 'web_sync/mysql_connection'

# Interact with Google API

class GoogleSync
   APPLICATION_NAME = ENV['GOOGLE_APP_NAME']
   LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'sync.log'))
   ENDORSER_SHEET_ID = ENV['GOOGLE_ENDORSER_SHEET_ID']
   ENDORSER_DATA_RANGE = 'Sheet1!A2:N'.freeze
   COLUMN_HEADING_RANGE = 'Sheet1!A1:N1'.freeze
   COLUMN_HEADINGS = ['First Name', 'Last Name', 'Title', 'Email', 'Phone', 'Organization Name',
                     'Website URL', 'Address1', 'Address2', 'City', 'State', 'Zip', 'Type', 'Vetted?']
   WP_ENDORSER_TABLE = 'bill_endorsers'

   attr_accessor :google_client
   attr_accessor :token
   attr_accessor :wp_client

   def initialize
      @token = OauthToken.google_service_token
      @google_client = initialize_google_client(@token)
      @wp_client = MysqlConnection.get_connection
   end

   def sync_endorsers
      current_endorsers = get_current_endorser_data
      clear_wb_endorsers
      # insert

   end

   def clear_wp_endorsers
      wp_client.query("DELETE from #{WP_ENDORSER_TABLE}")
   end

   def get_current_endorser_data
      google_client.get_spreadsheet_values(ENDORSER_SHEET_ID, ENDORSER_DATA_RANGE).values
   end

   # column headings must match and be in the same order to ensure sync works correctly
   def validate_data_columns
      column_headings == COLUMN_HEADINGS
   end

   def column_headings
      google_client.get_spreadsheet_values(ENDORSER_SHEET_ID, COLUMN_HEADING_RANGE)&.values&.first
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