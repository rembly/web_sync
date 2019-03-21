require 'rest-client'
require 'json'
require 'active_support/all'
require 'googleauth'
require 'fileutils'

# Generate token for interacting with Salesforce API
class OauthToken
  SALESFORCE_PWD = ENV['SALESFORCE_PWD']
  SALESFORCE_SECRET = ENV['SALESFORCE_SECRET']
  SALESFORCE_CLIENT_ID = ENV['SALESFORCE_CLIENT_ID']
  SALESFORCE_USER = ENV['SALESFORCE_USER']
  IS_PRODUCTION = ENV['ENVIRONMENT'].to_s == 'production'

  SANDBOX_TOKEN_URL = 'https://test.salesforce.com/services/oauth2/token'
  PRODUCTION_TOKEN_URL = 'https://login.salesforce.com/services/oauth2/token'

  SERVICE_ACCOUNT_KEY_FILE = 'google_sheet_sync.json'.freeze
  GOOGLE_SHEET_READONLY_SCOPE = 'https://www.googleapis.com/auth/spreadsheets.readonly'
  GOOGLE_SHEEET_READWRITE_SCOPE = 'https://www.googleapis.com/auth/spreadsheets'

  def self.salesforce_token
    token_url = IS_PRODUCTION ? PRODUCTION_TOKEN_URL : SANDBOX_TOKEN_URL
    p "Fetching salesforce token from #{token_url}"
    begin
      response = RestClient.post(token_url, { grant_type: 'password', client_id: SALESFORCE_CLIENT_ID, client_secret: SALESFORCE_SECRET,
                                                      username: SALESFORCE_USER, password: SALESFORCE_PWD})
      return JSON.parse(response.body)
    rescue RestClient::ExceptionWithResponse => e
      e.response
    end
  end

  def self.google_service_token(access: :readonly)
    scope = access == :readonly ? GOOGLE_SHEET_READONLY_SCOPE : GOOGLE_SHEEET_READWRITE_SCOPE
    authorizer = Google::Auth::ServiceAccountCredentials.make_creds( 
      json_key_io: File.open(SERVICE_ACCOUNT_KEY_FILE), scope: [scope])
    authorizer.fetch_access_token!
    authorizer
  end

end
