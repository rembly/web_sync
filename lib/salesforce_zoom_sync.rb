require_relative 'salesforce_sync'
require_relative 'zoom_sync'
require_relative './web_sync/email_notifier'
require 'active_support/all'
require 'awesome_print'
require 'pry'

# This will check Salesforce for users who should be in zoom but are not.
# It will also update SF intro call date for users who attended the intro call
# Initially this will be run as a nightly script
class SalesforceZoomSync
  EMAIL_NOTIFIER = EmailNotifier.new

  attr_accessor :sf
  attr_accessor :zoom_client
  attr_accessor :zoom_registrants
  attr_accessor :summary

  def initialize
    @sf = SalesforceSync.new
    @zoom_client = ZoomSync.new
  end

  def run_zoom_to_sf_sync
    set_logger('nightly_sync.log')
    @summary = ["Setting Intro Call Date. Zoom to Salesforce Sync for #{Date.today}"]
    @log.info("Starting nightly sync. Salesforce user: #{ENV['SALESFORCE_USER']}")
    sync_zoom_updates_to_sf
    send_summary_email
    wait_for_zoom_queue_thread
  end

  def run_sf_to_zoom_sync
    set_logger('weekly_sync.log')
    @summary = ["Registering People for Intro Call. Salesforce to Zoom Sync for #{Date.today}"]
    @log.info("Starting nightly sync. Salesforce user: #{ENV['SALESFORCE_USER']}")
    set_zoom_registrants
    sync_sf_updates_to_zoom
    send_summary_email
    wait_for_zoom_queue_thread
  end

  def sync_sf_updates_to_zoom
    @log.info('Syncing Salesforce users to Zoom..')
    # get SF users eligible to be added to zoom based on intro call date and rsvp
    eligible_sf_users = @sf.contacts_eligible_for_zoom

    # get the next intro call meeting occurrence
    next_call = @zoom_client.next_intro_call_occurrence
    LOG.error('Could not find next intro call instance or instance..') && return unless next_call&.dig('start_time').present?

    LOG.info("The next intro call is on #{next_call['start_time'].to_date}")

    # add eligibile sf users to zoom if necessary
    # @log.debug("#{eligible_sf_users.try(:size).to_i} SF users eligible for zoom: #{eligible_sf_users.try(:attrs)}")
    eligible_sf_users.select(&method(:sf_user_not_in_zoom?)).
                      tap(&method(:log_zoom_add)).
                      each{|user_to_add| @zoom_client.add_intro_meeting_registrant(user_to_add, next_call['occurrence_id'])}
  end

  def sync_zoom_updates_to_sf
    @log.info('Syncing Zoom updates to SF')
    # get all zoom users who have watched the most recent intro call for more than the minimum duration
    sync_intro_call_webinar_users
  end

  private

  def send_summary_email
    EMAIL_NOTIFIER.send_email(subject: summary[0], body: summary.join("\n"))
  end

  def sync_intro_call_webinar_users
    intro_participants = @zoom_client.intro_call_participants
    @log.debug("#{intro_participants.try(:size).to_i} Intro Call users:")
    add_meeting_participants(intro_participants)
  end

  def add_meeting_participants(meeting_participants)
    participants = meeting_participants.dig('participants').select(&method(:valid_intro_call_duration)).
                    select(&method(:valid_zoom_user_for_sf?))
    @log.debug('No intro call participants to sync') && return unless participants.any?
    intro_call_date = participants.try(:first).dig('join_time').try(:to_date)
    update_zoom_attendees(participants, intro_call_date)
    update_zoom_callers(participants, intro_call_date)
  end

  def update_zoom_attendees(participants, intro_call_date)
    matched_email = @sf.sf_users_for_zoom_emails(participants)
    log_sf_update(matched_email, 'attendees', intro_call_date)
    matched_email.each{|user| @sf.set_intro_date_for_contact(contact: user, date: intro_call_date) } if matched_email.try(:any?)
  end

  def update_zoom_callers(participants, intro_call_date)
    matched_phone = @sf.sf_users_for_zoom_callers(participants)
    log_sf_update(matched_phone, 'callers', intro_call_date)
    matched_phone.each{|user| @sf.set_intro_date_for_contact(contact: user, date: intro_call_date) } if matched_phone.try(:any?)
  end

  # log messages to logfile and build email summary for summary report
  def log(message)
    @log.info(message)
    summary << message
  end

  def log_zoom_add(users_to_add_to_zoom)
    log("Registering #{users_to_add_to_zoom.try(:size).to_i} users for Intro Call:")
    users_to_add_to_zoom.each{|user| log(sf_user_link(user))} if users_to_add_to_zoom.try(:any?)
  end

  def log_sf_update(sf_users, type, intro_date)
    log("Updating #{sf_users.try(:size).to_i} Salesforce records with Intro Call #{type} for #{intro_date}:")
    sf_users.each{|user| log(sf_user_print(user))} if sf_users.try(:any?)
  end

  # cache all users registered for intro call
  def set_zoom_registrants
    @zoom_registrants = @zoom_client.intro_call_registrants['registrants']
    @log.error('MAX registrants for intro call') if @zoom_registrants.try(:size).to_i == ZoomSync::MAX_PAGE_SIZE
  end

  def sf_user_not_in_zoom?(sf_user)
    ! sf_user_in_zoom?(sf_user)
  end

  def sf_user_in_zoom?(sf_user)
    # should we log if a user's email is in zoom but the name doesn't match? Or if an alternate email matches but not primary?
    zoom_user_from_sf_user(sf_user).present?
  end

  def zoom_user_from_sf_user(sf_user)
    all_sf_emails = SalesforceSync.all_emails_for_user(sf_user)
    # is there a zoom user whose email address matches any of the addresses for this SF user
    @zoom_registrants.find{|zoom_user| all_sf_emails.any?{|sf_email| zoom_user['email'].to_s.casecmp(sf_email).zero?}}
  end

  def valid_intro_call_duration(participant)
    participant.dig('duration').to_i >= ZoomSync::MINIMUM_DURATION_FOR_INTRO_CALL
  end

  def valid_zoom_user_for_sf?(participant)
    participant.dig('user_email').present? || SalesforceZoomSync.phone_participant?(participant)
  end

  def is_phone?(str)
    str.to_s =~ /^\d+$/
  end

  def sf_user_link(user)
    "<a href='https://na51.salesforce.com/#{user.Id}'>#{sf_user_print(user)}</a>"
  end

  def sf_user_print(user)
    "#{user.LastName}, #{user.FirstName}, #{SalesforceSync.primary_email(user)}"
  end

  def set_logger(logger_name)
    @log = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', logger_name))
  end

  # wait for Zoom queue consumer thread to finish and shut down before exiting
  def wait_for_zoom_queue_thread
    @zoom_client.stop_request_queue_consumer
    @zoom_client.queue_consumer.join
    @log.info('Finished SF to Zoom sync')
  end
end
