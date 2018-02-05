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

  INTRO_CALL_RSVP_FIELD = 'Intro_Call_RSVP_Date__c'
  INTRO_CALL_DATE_FIELD = 'Date_of_Intro_Call__c'
  EMAIL_FIELDS = %w(Email Alternate_Email__c CCL_Email_Three__c CCL_Email_Four__c)
  PHONE_FIELDS = %w(Phone HomePhone Mobile_Phone_Formatted2__c)
  REQUIRED_FIELDS = %w(Id FirstName LastName)
  SELECT_FIELDS = [*REQUIRED_FIELDS, *PHONE_FIELDS, *EMAIL_FIELDS, INTRO_CALL_DATE_FIELD, INTRO_CALL_RSVP_FIELD]

  def initialize
    @token = OauthToken.salesforce_token
    @client = initialize_client(@token)
  end

  def all_contacts
    @client.query("SELECT Id, FirstName, LastName, Birthdate, Email, Intro_Call_RSVP_Date__c FROM Contact")
  end

  def contacts_eligible_for_zoom
    contacts = @client.query(<<-QUERY)
      SELECT #{SELECT_FIELDS.join(', ')}
      FROM Contact
      WHERE Intro_Call_RSVP_Date__c != null AND Intro_Call_RSVP_Date__c >= #{(Date.today - 30.days).rfc3339}
      AND (#{one_field_present_for(EMAIL_FIELDS)}) 
      AND (#{all_fields_present_for(REQUIRED_FIELDS)})
    QUERY

    # we can't completely filter with SQL, double check RSVP date relative to intro call
    contacts.select(&method(:valid_intro_call_date?))
  end

  def sf_users_for_zoom_users(zoom_users)
    email_list = zoom_users.map{|zu| zu.dig('email')}.compact.join(', ')

    contacts = @client.query(<<-QUERY)
      SELECT #{SELECT_FIELDS.join(', ')}
      FROM Contact
      WHERE Email IN(#{email_list}) OR Alternate_Email__c IN (#{email_list})
    QUERY
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
    client.select('Contact', id, SELECT_FIELDS, 'Id')
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
      return intro_date.blank? || ((rsvp_date > intro_date + 1.day) && (rsvp_date > Date.today - 30.days))
    end
  end

  def self.user_has_email_address?(sf_user)
    EMAIL_FIELDS.map(&:to_sym).any?{|email_field| sf_user.try(email_field).present?}
  end

  def self.all_emails_for_user(sf_user)
    EMAIL_FIELDS.map(&:to_sym).collect{|email_field| sf_user.try(email_field)}.compact
  end

  # move from Email to CCL Email 4 picking the first one
  def self.primary_email(sf_user)
    self.all_emails_for_user(sf_user).try(:first)
  end

  # create user object from push message
  def self.sf_message_user(push_message)
    JSON.parse(push_message['sobject'].to_json, object_class: OpenStruct)
  end

  private

  def one_field_present_for(fields)
    fields.collect{|field_name| "#{field_name} != null"}.join(' OR ')
  end

  def all_fields_present_for(fields)
    fields.collect{|field_name| "#{field_name} != null"}.join(' AND ')
  end

  def initialize_client(token)
    # todo: sandbox host is for dev only
    Restforce.new(oauth_token: token['access_token'], instance_url: token['instance_url'], api_version: API_VERSION, host: SANDBOX_HOST)
  end

end
