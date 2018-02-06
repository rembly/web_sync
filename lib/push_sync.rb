require_relative 'salesforce_sync'
require_relative './zoom_sync'
require 'faye'
require 'active_support/all'

# This class registers to listen for Salesforce push notifications and syncs updates to zoom if required
# Note that instantiating this class blocks while waiting for updates
class PushSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'sync.log'))
  EMAIL_NOTIFICATION_TO = ENV['EMAIL_NOTIFICATION_TO']
  PUBSUB_TOPIC = 'ContactUpdated'

  attr_accessor :sf
  attr_accessor :zoom_client
  attr_accessor :zoom_users

  def initialize
    @sf = SalesforceSync.new
    @zoom_client = ZoomSync.new
    set_zoom_users
    start_sync_job
  end

  # Register for SF client updates via push topic. Add/update/remove users in Zoom as needed TODO: separate thread
  def start_sync_job
    EM.run do
      @sf.client.subscribe PUBSUB_TOPIC do |push_message|
        log_salesforce_push_update(push_message)
        sf_user = SalesforceSync.sf_message_user(push_message)

        if add_update_event?(push_message) && add_user_to_zoom?(sf_user)
          @zoom_client.add_sf_user(sf_user)
        elsif delete_event?(push_message) && sf_user_in_zoom?(sf_user)
          @zoom_client.remove_user!(zoom_user_from_sf_user(sf_user)['id'])
        end
      end
    end
  end

  private

  def add_update_event?(message)
    #verify create type
    %w(updated created).include?(message.dig('event', 'type'))
  end

  def delete_event?(message)
    # verify delete type
    %w(deleted).include?(message.dig('event', 'type'))
  end

  def lookup_salesforce_user(id)
    user = @sf.contact_by_id(id: id)
    LOG.info("User found in salesforce: #{user.inspect}") if user.present?
    user
  end

  # Push notification goes to script for any based on intro call date and intro call RSVP date
  def add_user_to_zoom?(sf_user)
    valid_user_for_zoom?(sf_user) && !sf_user_in_zoom?(sf_user)
  end

  # cache all zoom users, use this rather than re-querying. Maybe only need email address.. for now get everything
  # TODO: clear cache on update of zoom TODO: ensure query honors zoom API query limit
  def set_zoom_users
    @zoom_users = @zoom_client.all_users['users']
  end

  # SF user has all necessary fields and should be added based on intro call fields
  def valid_user_for_zoom?(sf_user)
    [sf_user.try(:FirstName), sf_user.try(:LastName)].all?(&:present?) &&
        SalesforceSync.user_has_email_address?(sf_user) &&
        @sf.valid_intro_call_date?(sf_user)
  end

  def sf_user_in_zoom?(sf_user)
    # should we log if a user's email is in zoom but the name doesn't match? Or if an alternate email matches but not primary?
    zoom_user_from_sf_user(sf_user).present?
  end

  def zoom_user_from_sf_user(sf_user)
    all_sf_emails = SalesforceSync.all_emails_for_user(sf_user)
    # is there a zoom user whose email address matches any of the addresses for this SF user
    @zoom_users.find{|zoom_user| all_sf_emails.any?{|sf_email| zoom_user['email'].to_s.casecmp(sf_email).zero?}}
  end

  # messages look like: {"event"=>{"createdDate"=>"2018-01-25T13:18:00.896Z", "replayId"=>7, "type"=>"updated"}, "sobject"=>{"Email"=>"[primary_email]",
  # "Welcome_Email_Sent__c"=>true, "Alternate_Email__c"=>"[alternate_email]", "Id"=>"[Id]", "Birthdate"=>"1979-02-12T00:00:00.000Z"}}
  def log_salesforce_push_update(message)
    LOG.info("Message Received. User updated: #{message.inspect}")
  end

end
