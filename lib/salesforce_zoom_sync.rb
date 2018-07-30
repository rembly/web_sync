require_relative 'salesforce_sync'
require_relative 'zoom_sync'
require_relative './web_sync/email_notifier'
require_relative './web_sync/intro_call_data'
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
    set_logger('weekly_sync.log')
    @summary = ["Setting Intro Call Date. Zoom to Salesforce Sync for #{Date.today}"]
    @log.info("Starting nightly sync. Salesforce user: #{ENV['SALESFORCE_USER']}")
    sync_zoom_updates_to_sf
    send_summary_email
    wait_for_zoom_queue_thread
  end

  def run_sf_to_zoom_sync
    set_logger('nightly_sync.log')
    @summary = ["Registering People for Intro Call. Salesforce to Zoom Sync for #{Date.today}"]
    @log.info("Starting nightly sync. Salesforce user: #{ENV['SALESFORCE_USER']}")
    set_zoom_registrants
    sync_sf_updates_to_zoom
    send_summary_email
    wait_for_zoom_queue_thread
  end

  def run_ocat_zoom_to_sf_sync
    set_logger('nightly_ocat.log')
    @summary = ["Syncing OCAT Calls to Salesforce for #{Date.today}"]
    @log.info("Starting nightly sync. Salesforce user: #{ENV['SALESFORCE_USER']}")
    sync_ocat_updates_to_sf
    send_summary_email('brett@citizensclimate.org,bryan.hermsen@citizensclimate.org')
    wait_for_zoom_queue_thread
  end

  def sync_sf_updates_to_zoom
    @log.info('Syncing Salesforce users to Zoom..')
    # get SF users eligible to be added to zoom based on intro call date and rsvp
    eligible_sf_users = @sf.contacts_eligible_for_zoom

    # get the next intro call meeting occurrence
    next_call = @zoom_client.next_intro_call_occurrence
    @log.error('Could not find next intro call instance or instance..') && return unless next_call&.dig('start_time').present?
    @log.info("The next intro call is on #{next_call['start_time'].to_date}. Occurrence ID: #{next_call['occurrence_id']}")
    # log intro call occurrence ID to file. Only write if not present in file
    IntroCallData.set_intro_call_occurrence(date: next_call['start_time'].to_datetime&.localtime&.to_date, occurrence_id: next_call['occurrence_id'])
    # add eligibile sf users to zoom if necessary
    eligible_sf_users.select(&method(:sf_user_not_in_zoom?)).
                      tap(&method(:log_zoom_add)).
                      each{|user_to_add| @zoom_client.add_intro_meeting_registrant(user_to_add, next_call['occurrence_id'])}
  end

  def sync_zoom_updates_to_sf
    @log.info('Syncing Zoom updates to SF')
    # get all zoom users who have watched the most recent intro call for more than the minimum duration
    sync_intro_call_webinar_users
    # sync_ocat_webinar_registrants
    # sync_ocat_webinar_users
  end

  def sync_ocat_updates_to_sf
    @log.info('Syncing OCAT updates to SF')
    sync_ocat_webinar_registrants
    sync_ocat_webinar_users
  end

  private

  def send_summary_email(to = nil)
    EMAIL_NOTIFIER.send_email(subject: summary[0], body: summary.join("\n"), to: to)
  end

  def sync_intro_call_webinar_users
    intro_participants = @zoom_client.intro_call_participants
    @log.debug("#{intro_participants.try(:size).to_i} Intro Call users:")
    add_meeting_participants(intro_participants)
  end

  def sync_ocat_webinar_users
    @log.debug('Setting OCAT attendance...')
    ocat_1 = @zoom_client.ocat_1_participants.dig('participants').select(&method(:valid_ocat_call_duration)).select(&method(:valid_zoom_user_for_sf?))
    ocat_2 = @zoom_client.ocat_2_participants.dig('participants').select(&method(:valid_ocat_call_duration)).select(&method(:valid_zoom_user_for_sf?))
    ocat_1_date = ocat_1.try(:first).dig('join_time')&.to_datetime&.localtime&.to_date
    ocat_2_date = ocat_2.try(:first).dig('join_time')&.to_datetime&.localtime&.to_date
    @log.debug("#{ocat_1&.size.to_i} attended OCAT 1 on #{ocat_1_date} and #{ocat_2&.size.to_i} attended OCAT 2 on #{ocat_2_date}")
    # TODO do we need to email people who RSVPed but missed the call?
    add_ocat_participants(ocat_1, ocat_1_date)
    add_ocat_participants(ocat_2, ocat_2_date)
  end

  def add_ocat_participants(participants, ocat_date)
    @log.debug("No OCAT call participants to sync for #{ocat_date}") && return unless participants.any?
    matched_email = update_zoom_attendees(participants, ocat_date, "OCAT Participants", 'New_Member_Call_Date__c', true)
    matched_phone = update_zoom_callers(participants, ocat_date, "OCAT Call-Ins", 'New_Member_Call_Date__c', true)
    log_unmatched_in_sf(matched_email.to_a | matched_phone.to_a, participants, "OCAT #{ocat_date}")
    # log_missed_call(participants, matched_email.to_a | matched_phone.to_a)
  end

  def sync_ocat_webinar_registrants
    @log.debug('RSVPing for OCAT calls...')
    # need to set RSVP
    next_ocat_1 = @zoom_client.next_ocat_1_occurrence.dig('start_time')&.to_datetime&.localtime&.to_date
    next_ocat_2 = @zoom_client.next_ocat_2_occurrence.dig('start_time')&.to_datetime&.localtime&.to_date

    ocat_1 = @zoom_client.ocat_1_registrants.dig('registrants').select(&method(:valid_zoom_user_for_sf?))
    ocat_2 = @zoom_client.ocat_2_registrants.dig('registrants').select(&method(:valid_zoom_user_for_sf?))
    @log.debug("#{ocat_1&.size.to_i} registrants for OCAT #{next_ocat_1} and #{ocat_2&.size.to_i} registrants for OCAT #{next_ocat_2}")
    matched_1 = update_zoom_attendees(ocat_1, next_ocat_1, "OCAT Registrants", SalesforceSync::OCAT_RSVP_FIELD)
    matched_2 = update_zoom_attendees(ocat_2, next_ocat_2, "OCAT Registrants", SalesforceSync::OCAT_RSVP_FIELD)
    log_unmatched_in_sf(matched_1.to_a, ocat_1, "OCAT #{next_ocat_1} RSVP")
    log_unmatched_in_sf(matched_2.to_a, ocat_2, "OCAT #{next_ocat_2} RSVP")
  end

  def resv_ocat_registrants(registrants, ocat_date)
    @log.debug("No OCAT registrants to sync for #{ocat_date}") && return unless registrants.any?
    matched_email = @sf.sf_users_for_zoom_emails(registrants)
    log_sf_update(matched_email, 'OCAT registrants', ocat_date)
    matched_email.each{|user| @sf.set_ocat_rsvp_for_contact(contact: user, date: ocat_date) } if matched_email.try(:any?)
    log_unmatched_in_sf(matched_email.to_a, registrants, "OCAT #{ocat_date} RSVP")
    matched_email
  end

  def add_meeting_participants(meeting_participants)
    participants = meeting_participants.dig('participants').select(&method(:valid_intro_call_duration)).
                    select(&method(:valid_zoom_user_for_sf?))
    @log.debug('No intro call participants to sync') && return unless participants.any?
    intro_call_date = participants.try(:first).dig('join_time')&.to_datetime&.localtime&.to_date
    matched_email = update_zoom_attendees(participants, intro_call_date, 'Intro Call Attendees', SalesforceSync::INTRO_CALL_DATE_FIELD)
    matched_phone = update_zoom_callers(participants, intro_call_date, 'Intro Call Callers', SalesforceSync::INTRO_CALL_DATE_FIELD)
    log_unmatched_in_sf(matched_email.to_a | matched_phone.to_a, participants, 'Intro Call')
    # get intro call occurrence ID from file and record registrants who didn't show up
    log_missed_call(participants, matched_email.to_a | matched_phone.to_a)
  end

  def update_zoom_attendees(participants, call_date, call_type, date_field, only_new = false)
    @log.debug("No #{call_type} participants to sync for #{call_date}") && return unless participants.any?
    matched_email = @sf.sf_users_for_zoom_emails(participants)
    matched_email = matched_email.select{|c| c.send(date_field).blank? || c.send(date_field).to_date < call_date} if only_new
    log_sf_update(matched_email, call_type, call_date)
    matched_email.each{|user| @sf.set_contact_date(contact: user, date: call_date, date_field: date_field) } if matched_email.try(:any?)
    matched_email
  end

  def update_zoom_callers(participants, call_date, call_type, date_field, only_new = false)
    @log.debug("No #{call_type} participants to sync for #{call_date}") && return unless participants.any?
    matched_phone = @sf.sf_users_for_zoom_callers(participants)
    matched_phone = matched_phone.select{|c| c.send(date_field).blank? || c.send(date_field).to_date < call_date} if only_new
    log_sf_update(matched_phone, call_type, call_date)
    matched_phone.each{|user| @sf.set_contact_date(contact: user, date: call_date, date_field: date_field) } if matched_phone.try(:any?)
    matched_phone
  end

  # log messages to logfile and build email summary for summary report
  def log(message)
    @log.info(message)
    summary << message << '<br/>'
  end

  def log_zoom_add(users_to_add_to_zoom)
    log("Registering #{users_to_add_to_zoom.try(:size).to_i} users for Intro Call:")
    users_to_add_to_zoom.each{|user| log(sf_user_link(user))} if users_to_add_to_zoom.try(:any?)
  end

  def log_sf_update(sf_users, type, date)
    # log("<br/>Updating #{sf_users.try(:size).to_i} Salesforce records with Intro Call #{type} for #{date}:")
    log("<br/>Updating #{sf_users.try(:size).to_i} Salesforce records with #{type} for #{date}:")
    sf_users.each{|user| log(sf_user_print(user))} if sf_users.try(:any?)
  end

  def log_missed_call(participants, matched_sf)
    last_occurrence_id = IntroCallData.get_latest_intro_call
    log('<br/>No previous intro call occurrence found') && return unless last_occurrence_id.present?
    registrants = @zoom_client.intro_call_registrants(last_occurrence_id).dig('registrants')
    # registrant SF records (because we need SF records for phone attendees)
    sf_registrants = @sf.sf_users_for_zoom_emails(registrants)
    # registrants missing from actual call. Log count and update intro missed flag
    missing_from_intro_call = sf_registrants.select{|registrant| matched_sf.none?{|attended| attended.Id == registrant.Id}}
    log("<br/>#{missing_from_intro_call.size} Registrants missed the intro call. Using occurrence #{last_occurrence_id}:")
    missing_from_intro_call.each{|user| log(sf_user_link(user)); @sf.set_intro_call_missed(contact: user) }
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

  def valid_ocat_call_duration(participant)
    participant.dig('duration').to_i >= ZoomSync::MINIMUM_DURATION_FOR_OCAT_CALL
  end

  def valid_zoom_user_for_sf?(participant)
    participant.dig('user_email').present? || participant.dig('email').present? || SalesforceSync.phone_participant?(participant)
  end

  def is_phone?(str)
    str.to_s =~ /^\d+$/
  end

  def log_unmatched_in_sf(matched_sf, zoom_participants, webinar_type)
    log("No Zoom users for #{webinar_type} were unmatched") && return if (matched_sf.to_a.none? || zoom_participants.to_a.none?)

    zoom_participants.select{|zoom_user| zoom_user_not_in_sf_list(zoom_user, matched_sf)}.
                      tap{|unmatched| 
                        if unmatched.size > 0
                          log("<br/>#{unmatched.size} Zoom #{webinar_type} users could not be found in Salesforce:") 
                        end
                      }.each{|unmatched_intro_attendee| log(zoom_user_print(unmatched_intro_attendee))}
  end

  def zoom_user_not_in_sf_list(zoom_user, sf_list)
    sf_list.none? do |sf_user|
      SalesforceSync.all_emails_for_user(sf_user).any?{|sf_email| zoom_user['user_email'].to_s.casecmp(sf_email).zero?} ||
          SalesforceSync.all_phone_numbers_for_user(sf_user).any?{|sf_phone| phone_match?(sf_phone, zoom_user['name'])}
    end
  end

  def phone_match?(sf_phone, zoom_phone)
    sf = sf_phone.to_s.gsub(/[^\d]/,'')
    sf.include?(zoom_phone.to_s) || zoom_phone.to_s.include?(sf)
  end

  def sf_user_link(user)
    "<a href='https://na51.salesforce.com/#{user.Id}'>#{sf_user_print(user)}</a>"
  end

  def sf_user_print(user)
    "#{user.LastName}, #{user.FirstName}, #{SalesforceSync.primary_email(user)}"
  end

  def zoom_user_print(user)
    name = "Name: #{user.dig('name')}"
    user.dig('user_email').present? ? name + ", Email: #{user.dig('user_email')}" : name
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
