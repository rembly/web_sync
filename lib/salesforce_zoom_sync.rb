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
    sync_sf_updates_to_zoom
    sync_zoom_updates_to_sf
  end

  def sync_sf_users_to_zoom
    # get SF users eligible to be added to zoom based on intro call date and rsvp
    eligible_sf_users = @sf.contacts_eligible_for_zoom
    # add eligibile sf users to zoom if necessary
    eligible_sf_users.select(&method(:sf_user_not_in_zoom?)).each{|user_to_add| @zoom_client.add_sf_user(user_to_add)}
  end

  def sync_zoom_updates_to_sf
    # get all zoom users who have watched the most recent intro call for more than the minimum duration
    participants = @zoom_client.valid_intro_call_meeting_participants

    # get all SF users matching those participants
    # hash with zoom -> sf user
    matching_users = @sf.sf_users_for_zoom_users(partcipants)

    # set the intro call date based for those users
  end

  private

  # cache all zoom users, use this rather than re-querying. Maybe only need email address.. for now get everything
  # TODO: clear cache on update of zoom TODO: ensure query honors zoom API query limit
  def set_zoom_users
    @zoom_users = @zoom_client.all_users['users']
  end

  def sf_user_not_in_zoom?(sf_user)
    ! sf_user_in_zoom?(sf_user)
  end

  def sf_user_in_zoom?(sf_user)
    # should we log if a user's email is in zoom but the name doesn't match? Or if an alternate email matches but not primary?
    zoom_user_from_sf_user(sf_user).present?
  end

  def zoom_user_from_sf_user(sf_user)
    @zoom_users.find{|zoom_user| sf_user.try(:Email).to_s.casecmp(zoom_user['email']).zero?}
  end

end
