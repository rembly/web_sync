# frozen_string_literal: true

require 'rest-client'
require 'json'
require 'active_support/all'
require 'pry'

# TODO: this needs tweaked for paging in order to be used outside of SWC
class ThrottledApiClient
  HALT_CALL_QUEUE_SIGNAL = :stop
  DEFAULT_API_RATE = 0.4

  attr_accessor :api_url
  attr_accessor :queue_consumer
  attr_reader :call_queue
  attr_reader :api_token
  attr_reader :time_between_calls

  attr_reader :api_call_count

  def initialize(api_url:, max_calls_sec: DEFAULT_API_RATE, time_between_calls: DEFAULT_API_RATE, token_method:, logger:)
    @call_queue = Queue.new
    @queue_consumer = start_request_queue_consumer
    @api_url = api_url
    @max_calls_sec = max_calls_sec
    @time_between_calls = time_between_calls
    @token_method = token_method
    @api_token = token_method.call
    @logger = logger

    @api_call_count = 0
  end

  def call(endpoint:, params: {})
    base_uri = URI.join(@api_url, endpoint).to_s
    begin
      response = RestClient.get(base_uri, Authorization: "Bearer #{@api_token}", params: params)
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

  def send_delete(endpoint:, params: {})
    base_uri = URI.join(@api_url, endpoint).to_s
    begin
      RestClient.delete(base_uri, Authorization: "Bearer #{@api_token}")
      @logger.info("Deleted: #{endpoint}")
      # return handle_response(response)
    rescue RestClient::ExceptionWithResponse => e
      return handle_response(e.response)
    end
  end

  # schedule call for later, taking API limit into account. Passes results of call to callback
  def queue_delete(endpoint:, &callback)
    @call_queue << lambda {
      send_delete(endpoint: endpoint)
    }
  end

  def put(endpoint:, data:, params: {})
    base_uri = [URI.join(@api_url, endpoint).to_s, params.to_query].compact.join('?')
    begin
      RestClient.put(base_uri, data.to_json, content_type: :json, accept: :json, Authorization: "Bearer #{@api_token}")
    rescue RestClient::ExceptionWithResponse => e
      return handle_response(e.response)
    end
  end

  # handle token reset
  def reset_token
    @logger.info('Resetting token...')
    @api_token = @token_method.call
  end

  # create an account and send email
  def post(endpoint:, data:, params: {})
    base_uri = [URI.join(@api_url, endpoint).to_s, params.to_query].compact.join('?')
    begin
      RestClient.post(base_uri, data.to_json, content_type: :json, accept: :json, Authorization: "Bearer #{@api_token}")
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
      results = JSON.parse(response)
      return gather_pages?(response) ? merge_results(results, get_next_page(response)) : results
    else
      # TODO: potentially handle rate limit
      @logger.error("FAILED request #{response.request}: MESSAGE: #{JSON.parse(response)}")
      return JSON.parse(response)
    end
   end

  # gather pages if there is a next_page token and the result set contains participants
  def gather_pages?(response)
    response.headers.key?(:link) && response.headers[:link].include?("rel=\"next")
  end

  # get next page by re-sending same request but with next page token. This will block for max api call rate duration
  # TODO: have this be injected in order to be generic
  def get_next_page(response)
    next_page_url = response.headers[:link].match(/^<([^>]*)>; rel=\"next/)
    request_uri = URI.parse(next_page_url.captures.first)
    # TODO remove.. not generic
    base_uri = '/services/4.0/'
    endpoint = [request_uri.path.split(base_uri).last, request_uri.query].join('?')
    sleep @time_between_calls
    call(endpoint: endpoint)
  end

  # TODO: Generify
  def merge_results(r1, r2)
    r1.concat(r2)
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
      while (call_request = @call_queue.pop)
        break if call_request == HALT_CALL_QUEUE_SIGNAL

        call_request.call
        sleep @max_calls_sec
      end

      @logger.info('Sync queue halt signal received, ending thread')
    end
  end
end
