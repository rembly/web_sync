require 'restforce'
require 'json'
require 'active_support/all'
require_relative 'web_sync/oauth_token'

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

  DATE_OF_INTRO_CALL_FIELD = 'Date_of_Intro_Call__c'
  INTRO_CALL_RSVP_FIELD = 'Intro_Call_RSVP_Date__c'
  INTRO_CALL_DATE_FIELD = 'Date_of_Intro_Call__c'
  EMAIL_FIELDS = %w(Email Alternate_Email__c CCL_Email_Three__c CCL_Email_Four__c)
  PHONE_FIELDS = %w(Phone HomePhone Mobile_Phone_Formatted2__c)

  def initialize
    @token = OauthToken.salesforce_token
    @client = initialize_client(@token)
  end

  def all_contacts
    @client.query("SELECT Id, FirstName, LastName, Birthdate, Email, Intro_Call_RSVP_Date__c FROM Contact")
  end

  def set_intro_call_date(contact_id:, date:)
    @client.update('Contact', Id: contact_id, Intro_Call_RSVP_Date__c: date.rfc3339)
  end

  def set_intro_date_for_contact(contact:, date:)
    contact.Intro_Call_RSVP_Date__c = date.rfc3339
    contact.save
  end

  # fast lookup by ID of only the fields we need for sync
  def contact_by_id(id:)
    client.select('Contact', id, %w(Id Email Name LastName Alternate_Email__c), 'Id')
  end

  def contact_all_fields(id:)
    @client.find('Contact', id)
  end

  def valid_intro_call_date?(sf_user)
    rsvp_field = INTRO_CALL_RSVP_FIELD.to_sym
    intro_date = INTRO_CALL_DATE_FIELD.to_sym
    if sf_user.try(rsvp_field).present?
      rsvp_date = sf_user.try(rsvp_field).to_date
      intro_date = sf_user.try(intro_date).present? ? sf_user.try(intro_date).to_date : nil
      return intro_date.empty? || ((rsvp_date > intro_date + 1.day) && (rsvp_date > Date.today - 30.days))
    end
  end

  private

  def initialize_client(token)
    # todo: sandbox host is for dev only
    Restforce.new(oauth_token: token['access_token'], instance_url: token['instance_url'], api_version: API_VERSION, host: SANDBOX_HOST)
  end

end
