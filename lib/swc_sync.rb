# frozen_string_literal: true

require 'rest-client'
require 'json'
require 'active_support/all'
require_relative 'web_sync/json_web_token'
require_relative './zoom_sync'
require 'csv'

# Rate Limiting Headers
# X-Rate-Limit-Limit – Number of requests allowed in the time frame 100 requests per 60 seconds
# X-Rate-Limit-Remaining – Number of requests let in the current time frame
# X-Rate-Limit-Reset – Seconds left in the current me frame
# TODO: Abstract Rest Methods and Throttling to base class with ZoomSync
class SwcSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'swc.log'))
  HALT_CALL_QUEUE_SIGNAL = :stop
  MAX_CALLS_PER_SECOND = 1.5 # 1 second limit plus buffer
  API_URL = 'http://cclobby.smallworldlabs.com/services/4.0/'
  FILES_PATH = ENV['BUDDY_FILE_PATH']
  BUDDY_FILES_CSV = File.join(File.dirname(__FILE__), '..', 'data', 'buddy_drive_files.csv')
  DRIVE_COLUMNS = %i[id email path title description mime_type].freeze

  # queue for rate_limited api calls
  attr_reader :call_queue
  attr_reader :last_response
  attr_accessor :queue_consumer
  attr_accessor :swc_token
  attr_accessor :users

  def initialize
    @swc_token = JsonWebToken.swc_token
    @call_queue = Queue.new
    @queue_consumer = start_request_queue_consumer
  end

  def get_users
    @users.present? ? @users : @users = call(endpoint: 'users')
  end

  def upload_files
    CSV.foreach(BUDDY_FILES_CSV) { |row| upload_file(row[1], row[2], row[3], row[4]) }
  end

  def upload_file(email, url, title, description)
    id = find_user_id_from_email(email)
    if id.present?
      filename = File.basename(URI.parse(url)&.path)
      file = File.new(File.join(FILES_PATH, filename), 'rb')
      # LOG.info("User/File found for #{email} / #{filename}")
      begin
        RestClient.post(URI.join(API_URL, 'files').to_s, { file: file, title: title, description: description,
                                                           public: false, userId: id }, Authorization: "Bearer #{swc_token}")
      #   LOG.info("User/File uploaded #{email} / #{filename}")
      rescue RestClient::ExceptionWithResponse => e
        return handle_response(e.response)
      end
   end
  end

  def find_user_id_from_email(email)
    get_users.find { |u| u['emailAddress'] == email }.try(:dig, 'userId')
  end

  def call(endpoint:, params: {})
    base_uri = URI.join(API_URL, endpoint).to_s
    begin
      response = RestClient.get(base_uri, Authorization: "Bearer #{swc_token}", params: params)
      return handle_response(response)
    rescue RestClient::ExceptionWithResponse => e
      return handle_response(e.response)
    end
  end

  # schedule call for later, taking API limit into account. Passes results of call to callback
  def queue_call(endpoint:, params:)
    @call_queue << lambda {
      results = call(endpoint: endpoint, params: params)
      yield(results)
    }
  end

  # create an account and send email
  def post(endpoint:, data:, params: {})
    base_uri = [URI.join(API_URL, endpoint).to_s, params.to_query].compact.join('?')
    begin
      RestClient.post(base_uri, data.to_json, content_type: :json, accept: :json, Authorization: "Bearer #{swc_token}")
    rescue RestClient::ExceptionWithResponse => e
      return handle_response(e.response)
    end
   end

  # schedule update for later, taking API limit into account. Passes results of update to optional callback
  def queue_post(endpoint:, data:, params: {}, &callback)
    @call_queue << lambda {
      results = post(endpoint: endpoint, data: data, params: params)
      yield(results) if callback.present?
    }
  end

  # return json representation of results or error object if call failed. This will handle client pagination
  def handle_response(response)
    return if response.blank?
    @last_response = response

    if success_response?(response)
      return JSON.parse(response)
    else
      # TODO: potentially handle rate limit
      LOG.error("FAILED request #{response.request}: MESSAGE: #{JSON.parse(response)}")
      return JSON.parse(response)
    end
   end

  # all 200 responses indicate a success
  def success_response?(response)
    response.try(:code).to_s.starts_with?('2')
  end

  def stop_request_queue_consumer
    @call_queue << HALT_CALL_QUEUE_SIGNAL
  end

  # take API calls from the call queue and execute with API limits. Consumer expects callable object
  def start_request_queue_consumer
    Thread.new do
      while (call_request = @call_queue.pop) != HALT_CALL_QUEUE_SIGNAL
        call_request.call
        sleep MAX_CALLS_PER_SECOND
      end

      LOG.info('SWC sync queue halt signal received, ending thread')
    end
  end
end
