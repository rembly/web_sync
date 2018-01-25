require_relative 'salesforce_sync'
require_relative './zoom_sync'
require 'faye'
require 'active_support/all'

class WebSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'sync.log'))
  PUBSUB_TOPIC = 'ContactUpdated'

  attr_accessor :salesforce_client
  attr_accessor :zoom_client

  def initialize
    @salesforce_client = SalesforceSync.new
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

end
