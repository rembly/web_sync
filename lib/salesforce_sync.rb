require 'restforce'
require 'json'
require 'active_support/all'
require_relative 'web_sync/oauth_token'
require 'pry'

# Interact with Salesforce. Method included for setting intro call date
#
# Send dates to SF as: Date.today.rfc3339
# TODO: Adjust for timezone of server
class SalesforceSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'sync.log'))
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

  def sf_users_for_zoom_emails(zoom_users)
    email_list = zoom_users.map{|zoom_user| zoom_user.dig('user_email')}.compact

    matched_contacts = @client.query(<<-QUERY) if email_list.any?
      SELECT #{SELECT_FIELDS.join(', ')}
      FROM Contact
      WHERE #{quoted_email_list(email_list)}
    QUERY

    LOG.info("#{matched_contacts.size} Zoom participants found in SF by email")
    matched_contacts
  end

  # Look up SF users by phone number
  def sf_users_for_zoom_callers(zoom_callers)
    phone_list = zoom_callers.select{|zu| SalesforceSync.phone_participant?(zu)}.map{|zu| zu.dig('name')}.compact

    matched_by_phone = @client.search(<<-QUERY) if phone_list.any?
      FIND {#{phone_list.join(' OR ')}}
      IN PHONE FIELDS
      RETURNING Contact(#{SELECT_FIELDS.join(', ')})
    QUERY

    LOG.info("#{matched_by_phone.size} Zoom callers found in SF")
    matched_by_phone
  end

  def set_intro_call_date(contact_id:, date:)
    @client.update('Contact', Id: contact_id, Intro_Call_RSVP_Date__c: date.rfc3339)
  end

  def set_intro_date_for_contact(contact:, date:)
    if contact.present? && (contact.Date_of_Intro_Call__c.blank? || contact.Date_of_Intro_Call__c.to_date < date)
      contact.Date_of_Intro_Call__c = date.rfc3339
      contact.save
    end
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

  def self.phone_participant?(participant = {})
    participant.dig('name').to_s =~ /^\d+$/
  end

  private

  def quoted_email_list(email_list)
    quoted_list = email_list.collect{|email| "'#{email}'"}.join(', ')
    EMAIL_FIELDS.collect{|field_name| "#{field_name} IN (#{quoted_list})"}.join(' OR ')
  end

  # returning US-formatted numbers
  def quoted_phone_list(phone_list)
    quoted_list = phone_list.collect{|number| "'#{formatted_phone_number(number)}'"}.join(', ')
    PHONE_FIELDS.collect{|field_name| "#{field_name} IN (#{quoted_list})"}.join(' OR ')
  end

  def one_field_present_for(fields)
    fields.collect{|field_name| "#{field_name} != null"}.join(' OR ')
  end

  def all_fields_present_for(fields)
    fields.collect{|field_name| "#{field_name} != null"}.join(' AND ')
  end

  # Create formatted phone number from Zoom number. TODO: this is only handling US numbers at this point
  def formatted_phone_number(number)
    ActiveSupport::NumberHelper.number_to_phone(number.to_s.gsub(/^1/, '').to_i, area_code: true)
  end

  def initialize_client(token)
    # todo: sandbox host is for dev only
    Restforce.new(oauth_token: token['access_token'], instance_url: token['instance_url'], api_version: API_VERSION, host: SANDBOX_HOST)
  end

end
