require_relative 'salesforce_sync'
require_relative './zoom_sync'
require 'faye'
require 'active_support/all'

class WebSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'sync.log'))
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

  def start_sync_job
    EM.run do
      @salesforce_client.client.subscribe PUBSUB_TOPIC do |message|
        log_salesforce_update(message)
      end
    end
  end

  # messages look like: {"event"=>{"createdDate"=>"2018-01-25T13:18:00.896Z", "replayId"=>7, "type"=>"updated"}, "sobject"=>{"Email"=>"[primary_email]",
  # "Welcome_Email_Sent__c"=>true, "Alternate_Email__c"=>"[alternate_email]", "Id"=>"[Id]", "Birthdate"=>"1979-02-12T00:00:00.000Z"}}
  def log_salesforce_update(message)
    LOG.info("Message Received. User updated: #{message.inspect}")
    message.dig('sobject', 'Id').tap(&method(:lookup_salesforce_user))
  end

  private

  def lookup_salesforce_user(id)
    user = @salesforce_client.contact_by_id(id: id)
    LOG.info("User found in salesforce: #{user.inspect}")
  end

  # Push notification goes to PHP script for any contact where Intro Call RSVP Date has been set or updated to today 
  # (including new Contacts where that is set on creation)
  def add_user_to_zoom?(user:)
    valid_user_for_zoom?(user) && sf_user_not_in_zoom?(user)
  end

  # cache all zoom users, use this rather than re-querying. Maybe only need email address.. for now get everything
  # TODO: clear cache on update of zoom
  # TODO: ensure query honors zoom API query limit
  def set_zoom_users
    @zoom_users = @zoom_client.all_users['users']
  end

  def valid_user_for_zoom?(user)
    [user.try(:FirstName), user.try(:LastName), user.try(:Email)].all?(&:present?)
  end

  def sf_user_not_in_zoom?(user)
    # should we log if a user's email is in zoom but the name doesn't match?
    @zoom_users.none?{|zoom_user| user.try(:Email).to_s.casecmp(zoom_user['email']).zero?}
  end

end
