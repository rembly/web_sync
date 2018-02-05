require_relative 'salesforce_sync'
require_relative './zoom_sync'
require 'active_support/all'
require 'pry'

# This will check Salesforce for users who should be in zoom but are not.
# Initially this will be run nightly
class SalesforceZoomSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'nightly_sync.log'))
  EMAIL_NOTIFICATION_TO = ENV['EMAIL_NOTIFICATION_TO']

  attr_accessor :sf
  attr_accessor :zoom_client
  attr_accessor :zoom_users

  def initialize
    @sf = SalesforceSync.new
    @zoom_client = ZoomSync.new
    set_zoom_users
  end

  private

  # cache all zoom users, use this rather than re-querying. Maybe only need email address.. for now get everything
  # TODO: clear cache on update of zoom TODO: ensure query honors zoom API query limit
  def set_zoom_users
    @zoom_users = @zoom_client.all_users['users']
  end

  # SF user has all necessary fields and has intro call date set
  def valid_user_for_zoom?(sf_user)
    [sf_user.try(:FirstName), sf_user.try(:LastName), sf_user.try(:Email)].all?(&:present?) && 
      @sf.valid_intro_call_date?(sf_user)
  end

  def sf_user_in_zoom?(sf_user)
    # should we log if a user's email is in zoom but the name doesn't match? Or if an alternate email matches but not primary?
    zoom_user_from_sf_user(sf_user).present?
  end

  def zoom_user_from_sf_user(sf_user)
    @zoom_users.find{|zoom_user| sf_user.try(:Email).to_s.casecmp(zoom_user['email']).zero?}
  end

  # messages look like: {"event"=>{"createdDate"=>"2018-01-25T13:18:00.896Z", "replayId"=>7, "type"=>"updated"}, "sobject"=>{"Email"=>"[primary_email]",
  # "Welcome_Email_Sent__c"=>true, "Alternate_Email__c"=>"[alternate_email]", "Id"=>"[Id]", "Birthdate"=>"1979-02-12T00:00:00.000Z"}}
  def log_salesforce_push_update(message)
    LOG.info("Message Received. User updated: #{message.inspect}")
    # message.dig('sobject', 'Id').tap(&method(:lookup_salesforce_user))
  end

end
