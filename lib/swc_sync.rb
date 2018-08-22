# frozen_string_literal: true

require 'rest-client'
require 'json'
require 'active_support/all'
require_relative 'web_sync/json_web_token'
require_relative './zoom_sync'

# Rate Limiting Headers
# X-Rate-Limit-Limit – Number of requests allowed in the time frame 100 requests per 60 seconds
# X-Rate-Limit-Remaining – Number of requests let in the current time frame
# X-Rate-Limit-Reset – Seconds left in the current me frame
class SwcSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'swc.log'))
  HALT_CALL_QUEUE_SIGNAL = :stop
  MAX_CALLS_PER_SECOND = 1.5 # 1 second limit plus buffer
  API_URL = 'http://cclobby.smallworldlabs.com/services/4.0/'

  FILE_CATEGORIES = {1: 'pdf, pptx, docx', 2: }

  # queue for rate_limited api calls
  attr_reader :call_queue
  attr_reader :last_response
  attr_accessor :queue_consumer
  attr_accessor :swc_token

  def initialize
    @swc_token = JsonWebToken.swc_token
    @call_queue = Queue.new
    @queue_consumer = start_request_queue_consumer
  end

  def add_file(file)
   # public: false
   # type: mime-type
   # file, title, public

  end

  # look for next_page_token to know whether to page. Max is 300.. may not hit this?
  def call(endpoint:, params: {})
    base_uri = URI.join(API_URL, endpoint).to_s
   #  params = params.merge(access_token: @swc_token)
    begin
      response = RestClient.get(base_uri, {Authorization: "Bearer #{swc_token}", params: params})
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

  # return json representation of results or error object if call failed. This will handle client pagination
  def handle_response(response)
    return if response.blank?
    @last_response = response

    if success_response?(response)
      return JSON.parse(response)
      # return gather_pages?(results) ? merge_users(results, get_next_page(response, results)) : results
    else
      # TODO: potentially handle 429 rate error by delaying/resending
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
