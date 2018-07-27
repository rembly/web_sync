require 'rest-client'
require 'json'
require 'active_support/all'
require_relative 'web_sync/json_web_token'
require_relative './salesforce_sync'

# Class for interacting with Zoom API
#
# Time.now.iso8601 - for date/time format
# Date.today.to_s - for date only format
#
class ZoomSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'sync.log'))
  ZOOM_API_URL = 'https://api.zoom.us/v2/'
  MAX_CALLS_PER_SECOND = 1.2 # 1 second limit plus buffer
  HALT_CALL_QUEUE_SIGNAL = :stop
  TOO_MANY_REQUESTS_ERROR = 429
  MAX_PAGE_SIZE = 300
  BASIC_USER_TYPE = 1
  INTRO_CALL_MEETING_ID = '2017201719'
  CLIMATE_ADVOCACY_WEBINAR_ID = '891518756' # sample webinar
  INTRO_MEETING_ID = '526383982' # sample recurring meeting
  INTRO_WEBINAR_ID = '847350531' # occurance 1519261200000
  OCAT_WEBINAR_1_ID = '116665200'
  OCAT_WEBINAR_2_ID = '548719620'
  MINIMUM_DURATION_FOR_INTRO_CALL = 600 # seconds / 10 minutes
  MINIMUM_DURATION_FOR_OCAT_CALL = 2400 # seconds / 10 minutes

  # queue for rate_limited api calls
  attr_reader :call_queue
  attr_reader :last_response
  attr_accessor :queue_consumer

  # fetches authentication token and starts thread for call queue
  def initialize
    @zoom_web_token = JsonWebToken.zoom_token
    @call_queue = Queue.new
    @queue_consumer = start_request_queue_consumer
  end

  # look for next_page_token to know whether to page. Max is 300.. may not hit this?
  def call(endpoint:, params: {})
    base_uri = URI.join(ZOOM_API_URL, endpoint).to_s
    params = params.merge({ access_token: @zoom_web_token, page_size: MAX_PAGE_SIZE })
    begin
      response = RestClient.get(base_uri, { params: params })
      return handle_response(response)
    rescue RestClient::ExceptionWithResponse => e
      return handle_response(e.response)
    end
  end

  # schedule call for later, taking API limit into account. Passes results of call to callback
  def queue_call(endpoint:, params:, &callback)
    @call_queue << lambda {
      results = call(endpoint: endpoint, params: params)
      callback.call(results)
    }
  end

  # create an account and send email
  def post(endpoint:, data:, params: {})
    base_uri = [URI.join(ZOOM_API_URL, endpoint).to_s, params.to_query].compact.join('?')
    begin
      # TODO: uncomment to enable zoom account creation. Account creation will send email to client
      # RestClient.post(base_uri, data.to_json, {content_type: :json, accept: :json, Authorization: "Bearer #{@zoom_web_token}"})
      LOG.info("Zoom client to be created: #{data}")
    rescue RestClient::ExceptionWithResponse => e
      return handle_response(e.response)
    end
  end

  # schedule update for later, taking API limit into account. Passes results of update to optional callback
  def queue_post(endpoint:, data:, params: {}, &callback)
    @call_queue << lambda {
      results = post(endpoint: endpoint, data: data, params: params)
      callback.call(results) if callback.present?
    }
  end

  def remove_user!(user_id_or_email:)
    @call_queue << lambda {
      user_path = ZOOM_API_URL + "users/#{user_id_or_email}"
      # TODO: uncomment to actually remove users. For now just log the request
      #results = RestClient.delete(user_path, {accept: :json, Authorization: "Bearer #{@zoom_web_token}"})
      LOG.info("Zoom user to delete: #{user_path}")
    }
  end

  # return json representation of results or error object if call failed. This will handle client pagination
  def handle_response(response)
    return if response.blank?
    @last_response = response

    if success_response?(response)
      results = JSON.parse(response)
      return gather_pages?(results) ? merge_users(results, get_next_page(response, results)) : results
    else
      # TODO: potentially handle 429 rate error by delaying/resending
      LOG.error("FAILED request #{response.request}: MESSAGE: #{JSON.parse(response)}")
      return JSON.parse(response)
    end
  end

  def stop_request_queue_consumer
    @call_queue << HALT_CALL_QUEUE_SIGNAL
  end

  ## Pre-defined calls to resources ##

  def meeting_report_for(from: Date.today - 2.months, to: Date.today - 1.month)
    call(endpoint: 'metrics/meetings', params: { from: from.to_s, to: to.to_s })
  end

  def daily_report(date: Date.today - 1.month)
    call(endpoint: 'report/daily/', params: { year: date.year, month: date.month })
  end

  def users_report(from: Date.today - 2.months, to: Date.today - 1.month)
    call(endpoint: 'report/users/', params: { from: from.to_s, to: to.to_s })
  end

  def fetch_user(user_id:)
    call(endpoint: "users/#{user_id}")
  end

  def all_users
    call(endpoint: 'users/')
  end

  def webinar_participants_report(id:)
    call(endpoint: "report/webinars/#{id}/participants")
  end

  # this defaults to 'approved' registrants only. But all invited are auto-approved at this point
  def intro_call_registrants(occurrence_id = nil)
    params = occurrence_id.present? ? {occurrence_id: occurrence_id} : {}
    call(endpoint: "webinars/#{INTRO_WEBINAR_ID}/registrants", params: params) 
  end
  
  def intro_call_participants; webinar_participants_report(id: INTRO_WEBINAR_ID) end
  def intro_call_details; call(endpoint: "webinars/#{INTRO_WEBINAR_ID}") end

  def next_intro_call_occurrence
    intro_call_details.dig('occurrences')&.first
  end

  def climate_advocacy_details; call(endpoint: "webinars/#{CLIMATE_ADVOCACY_WEBINAR_ID}") end
  def climate_advocacy_registrants; call(endpoint: "webinars/#{CLIMATE_ADVOCACY_WEBINAR_ID}/registrants") end
  def climate_advocacy_participants; webinar_participants_report(id: CLIMATE_ADVOCACY_WEBINAR_ID) end

  def next_ocat_1_occurrence; ocat_1_details.dig('occurrences')&.first end
  def ocat_1_details; call(endpoint: "webinars/#{OCAT_WEBINAR_1_ID}") end
  def ocat_1_registrants; call(endpoint: "webinars/#{OCAT_WEBINAR_1_ID}/registrants") end
  def ocat_1_participants; webinar_participants_report(id: OCAT_WEBINAR_1_ID) end

  def next_ocat_2_occurrence; ocat_2_details.dig('occurrences')&.first end
  def ocat_2_details; call(endpoint: "webinars/#{OCAT_WEBINAR_2_ID}") end
  def ocat_2_registrants; call(endpoint: "webinars/#{OCAT_WEBINAR_2_ID}/registrants") end
  def ocat_2_participants; webinar_participants_report(id: OCAT_WEBINAR_2_ID) end

  # get all ocat registrants
  def ocat_registrants; merge_users(ocat_1_registrants, ocat_2_registrants) end
  def ocat_participants; merge_users(ocat_1_participants, ocat_2_participants) end

  # this will send an invite to the passed in SF user's primary email to join zoom
  def add_sf_user(sf_user)
    email = SalesforceSync.primary_email(sf_user)
    LOG.info("SF user #{email.to_s} not found in zoom. Adding to Zoom")
    data = { action: 'create',
             user_info: {
                 email: email,
                 type: BASIC_USER_TYPE,
                 first_name: sf_user.FirstName,
                 last_name: sf_user.LastName,
             }
    }

    queue_post(endpoint: 'users/', data: data) { |results| LOG.debug("Post results: #{results}") }
  end

  # note that this triggers welcome meeting and adds them in 'approved' status
  def add_intro_meeting_registrant(sf_user, meeting_occurrence = nil)
    LOG.info("SF user not found in zoom. Adding to Zoom: #{sf_user.try(:as_json)}")
    params = meeting_occurrence.present? ? {occurrence_ids: meeting_occurrence} : {}
    data = {
        email: SalesforceSync.primary_email(sf_user),
        first_name: sf_user.FirstName,
        last_name: sf_user.LastName,
    }

    queue_post(endpoint: "webinars/#{INTRO_WEBINAR_ID}/registrants", data: data, params: params)
  end

  private

  # take API calls from the call queue and execute with API limits. Consumer expects callable object
  def start_request_queue_consumer
    Thread.new do
      while (call_request = @call_queue.pop) != HALT_CALL_QUEUE_SIGNAL
        call_request.call()
        sleep MAX_CALLS_PER_SECOND
      end

      LOG.info('Zoom sync queue halt signal received, ending thread')
    end
  end

  # all 200 responses indicate a success
  def success_response?(response)
    response.try(:code).to_s.starts_with?('2')
  end

  # gather pages if there is a next_page token and the result set contains participants
  def gather_pages?(results)
    (results.dig('next_page_token').present? && results.dig('participants').present?) ||
        (results.dig('page_number').to_i < results.dig('page_count').to_i && results.dig('registrants').present?)
  end

  # get next page by re-sending same request but with next page token. This will block for max api call rate duration
  def get_next_page(response, results)
    request_uri = URI.parse(response.request.url)
    endpoint = request_uri.path.gsub(/\/v2\//,'')
    exclude_params = %w(access_token next_page_token page_number)
    params = CGI.parse(request_uri.query).except(*exclude_params).inject({}){|map, (k, v)| map[k] = v.first; map}
    next_page_params = endpoint.include?('participants') ? {next_page_token: results.dig('next_page_token')} :
                           {page_number: results.dig('page_number').to_i + 1}
    sleep MAX_CALLS_PER_SECOND
    call(endpoint: endpoint, params: params.merge(next_page_params))
  end

  # merge the participant or registrant list of two result sets.
  # throw if one result set is an error?
  def merge_users(r1, r2)
    r1.deep_merge(r2){|key, r1, r2| %w(participants registrants).include?(key) ? r1 + r2 : r2}
  end
end
