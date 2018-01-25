require 'restforce'
require 'json'
require 'active_support/all'
require File.join(File.dirname(__FILE__), 'web_sync', 'oauth_token')

# Interact with Salesforce. Method included for setting intro call date
#
# Include in IRB: require File.join(File.dirname(__FILE__), 'lib', 'salesforce_sync')
# Sample Query: SELECT Name, FirstName, LastName, Birthdate, Email, Intro_Call_Done__c, Intro_Call_RSVP_Date__c FROM Contact
# Dates as: Date.today.rfc3339
# TODO: Adjust for timezone of server
class SalesforceSync
  API_VERSION = '38.0'
  SANDBOX_HOST = 'test.salesforce.com'
  attr_accessor :client
  attr_accessor :token

  def initialize
    @token = OauthToken.salesforce_token
    @client = initialize_client(@token)
  end

  def all_clients
    @client.query("SELECT Id, FirstName, LastName, Birthdate, Email, Intro_Call_RSVP_Date__c FROM Contact")
  end

  def set_intro_call_date(contact_id:, date:)
    @client.update('Contact', Id: contact_id, Intro_Call_RSVP_Date__c: date.rfc3339)
  end

  def set_intro_date_for_contact(contact:, date:)
    contact.Intro_Call_RSVP_Date__c = date.rfc3339
    contact.save
  end

  private

  def initialize_client(token)
    # todo: sandbox host is for dev only
    Restforce.new(oauth_token: token['access_token'], instance_url: token['instance_url'], api_version: API_VERSION, host: SANDBOX_HOST)
  end

end
