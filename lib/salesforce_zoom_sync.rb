require_relative 'salesforce_sync'
require_relative 'zoom_sync'
require_relative './web_sync/email_notifier'
require 'active_support/all'
require 'pry'

# This will check Salesforce for users who should be in zoom but are not.
# It will also update SF intro call date for users who attended the intro call
# Initially this will be run as a nightly script
class SalesforceZoomSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'nightly_sync.log'))
  EMAIL_NOTIFIER = EmailNotifier.new

  attr_accessor :sf
  attr_accessor :zoom_client
  attr_accessor :zoom_users
  attr_accessor :summary

  def initialize
    @sf = SalesforceSync.new
    @zoom_client = ZoomSync.new
    set_zoom_users
    @summary = ["Nightly Salesforce / Zoom Sync for #{Date.today}"]
    LOG.info('Starting nightly sync')
    sync_sf_updates_to_zoom
    sync_zoom_updates_to_sf
    LOG.info('Finished nightly sync')
    send_summary_email
  end

  def sync_sf_updates_to_zoom
    LOG.info('Syncing Salesforce users to Zoom..')
    # get SF users eligible to be added to zoom based on intro call date and rsvp
    eligible_sf_users = @sf.contacts_eligible_for_zoom
    # add eligibile sf users to zoom if necessary
    eligible_sf_users.select(&method(:sf_user_not_in_zoom?)).
                      tap{|users_to_add| log("Adding #{users_to_add.size} SF users to zoom")}.
                      each{|user_to_add| @zoom_client.add_sf_user(user_to_add)}
  end

  def sync_zoom_updates_to_sf
    LOG.info('Syncing Zoom updates to SF')
    # get all zoom users who have watched the most recent intro call for more than the minimum duration
    sync_intro_call_users
    sleep ZoomSync::MAX_CALLS_PER_SECOND
    sync_intro_call_webinar_users
  end

  private

  def send_summary_email
    EMAIL_NOTIFIER.send_email(subject: summary[0], body: summary.join("\n"))
  end

  def sync_intro_call_webinar_users
    intro_details = @zoom_client.intro_call_webinar_details
    intro_call_date = intro_details['start_time'].to_date
    intro_call_participants = @zoom_client.intro_call_webinar_participants(meeting_id: intro_details['uuid'])
    log("Syncing Intro Webinar from #{intro_call_date}")
    add_meeting_participants(intro_call_participants, intro_call_date)
  end

  def sync_intro_call_users
    intro_details = @zoom_client.intro_call_details
    intro_call_date = intro_details['start_time'].to_date
    intro_call_participants = @zoom_client.meeting_participants_report(meeting_id: intro_details['uuid'])
    log("Syncing Intro Call from #{intro_call_date}")
    add_meeting_participants(intro_call_participants, intro_call_date)
  end

  def add_meeting_participants(meeting_participants, intro_call_date)
    participants = meeting_participants.dig('participants').select(&method(:valid_intro_call_duration)).
                    select(&method(:valid_zoom_user_for_sf?))
    matched_users = @sf.sf_users_for_zoom_users(participants)
    log("#{participants.size} valid Zoom participants to sync. #{matched_users.size} matched in SF")
    # set the intro call date based for those users. TODO: may need to output multiple users found for same email etc..
    matched_users.each do |user|
      @sf.set_intro_date_for_contact(contact: user, date: intro_call_date)
    end
  end

  # log messages to logfile and build email summary for summary report
  def log(message)
    LOG.info(message)
    summary << message
  end

  # cache all zoom users, use this rather than re-querying. Maybe only need email address.. for now get everything
  # TODO: clear cache on update of zoom
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

  def valid_intro_call_duration(participant)
    participant.dig('duration').to_i >= ZoomSync::MINIMUM_DURATION_FOR_INTRO_CALL
  end

  def valid_zoom_user_for_sf?(participant)
    participant.dig('user_email').present?
  end

end
