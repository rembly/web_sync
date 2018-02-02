require_relative 'salesforce_sync'
require_relative './zoom_sync'
require 'faye'
require 'active_support/all'

class WebSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'sync.log'))
  EMAIL_NOTIFICATION_TO = ENV['EMAIL_NOTIFICATION_TO']
  PUBSUB_TOPIC = 'ContactUpdated'

  attr_accessor :salesforce_client
  attr_accessor :zoom_client
  attr_accessor :zoom_users

  def initialize
    @salesforce_client = SalesforceSync.new
    @zoom_client = ZoomSync.new
    set_zoom_users
    start_sync_job
  end

  # Register for SF client updates via push topic. Add/update/remove users in Zoom as needed
  # TODO: separate thread
  def start_sync_job
    EM.run do
      @salesforce_client.client.subscribe PUBSUB_TOPIC do |message|
        log_salesforce_push_update(message)
        if add_update_event?(message)
          sf_user = lookup_salesforce_user(message.dig('sobject', 'Id'))
          if add_user_to_zoom?(sf_user)
            LOG.info("SF user not found in zoom. Adding to Zoom")
            @zoom_client.add_sf_user(sf_user)
          end
        elsif delete_event?(message) && sf_user_in_zoom?(user)
          LOG.info("SF delete action, remove user from zoom")
          @zoom_client.remove_user!(zoom_user_from_sf_user(sf_user)['id'])
        end
      end
    end
  end

  private

  def lookup_salesforce_user(id)
    user = @salesforce_client.contact_by_id(id: id)
    LOG.info("User found in salesforce: #{user.inspect}")
  end

  # Push notification goes to PHP script for any contact where Intro Call RSVP Date has been set or updated to today 
  # (including new Contacts where that is set on creation)
  def add_user_to_zoom?(sf_user:)
    valid_user_for_zoom?(user) && !sf_user_in_zoom?(user)
  end

  # cache all zoom users, use this rather than re-querying. Maybe only need email address.. for now get everything
  # TODO: clear cache on update of zoom TODO: ensure query honors zoom API query limit
  def set_zoom_users
    @zoom_users = @zoom_client.all_users['users']
  end

  # SF user has all necessary fields and has intro call date set
  def valid_user_for_zoom?(sf_user)
    [sf_user.try(:FirstName), sf_user.try(:LastName), sf_user.try(:Email)].all?(&:present?) && 
      valid_intro_call_date?(sf_user)
  end

  def sf_user_in_zoom?(sf_user)
    # should we log if a user's email is in zoom but the name doesn't match? Or if an alternate email matches but not primary?
    zoom_user_from_sf_user(sf_user).present?
  end

  def valid_intro_call_date?(sf_user)
    rsvp_field = SalesforceSync::INTRO_CALL_RSVP_FIELD.to_sym
    intro_date = SalesforceSync::INTRO_CALL_DATE_FIELD.to_sym
    if sf_user.try(rsvp_field).present?
      rsvp_date = sf_user.try(rsvp_field).to_date
      intro_date = sf_user.try(intro_date).present? ? sf_user.try(intro_date).to_date : nil
      return intro_date.empty? || ((rsvp_date > intro_date + 1.day) && (rsvp_date > Date.today - 30.days))
    end
  end

  def zoom_user_from_sf_user(sf_user)
    @zoom_users.find{|zoom_user| user.try(:Email).to_s.casecmp(zoom_user['email']).zero?}
  end

  # messages look like: {"event"=>{"createdDate"=>"2018-01-25T13:18:00.896Z", "replayId"=>7, "type"=>"updated"}, "sobject"=>{"Email"=>"[primary_email]",
  # "Welcome_Email_Sent__c"=>true, "Alternate_Email__c"=>"[alternate_email]", "Id"=>"[Id]", "Birthdate"=>"1979-02-12T00:00:00.000Z"}}
  def log_salesforce_push_update(message)
    LOG.info("Message Received. User updated: #{message.inspect}")
    message.dig('sobject', 'Id').tap(&method(:lookup_salesforce_user))
  end

end
