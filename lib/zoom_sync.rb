require 'rest-client'
require 'json'
require 'active_support/all'
require_relative'web_sync/json_web_token'
require_relative './salesforce_sync'

# Time.now.iso8601 - for date/time format
# Date.today.to_s - for date only format
# require File.join(File.dirname(__FILE__), 'lib', 'zoom_sync')
class ZoomSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'sync.log'))
  ZOOM_API_URL = 'https://api.zoom.us/v2/'
  BASIC_USER_TYPE = 1

  def initialize
    @zoom_web_token = JsonWebToken.zoom_token
  end

  def call(endpoint:, params: {})
    base_uri = URI.join(ZOOM_API_URL, endpoint).to_s
    params = params.merge({access_token: @zoom_web_token})
    response = RestClient.get(base_uri, {params: params})
    JSON.parse(response)
  end

  def post(endpoint:, data:)
    base_uri = URI.join(ZOOM_API_URL, endpoint).to_s
    # TODO: uncomment to enable zoom account creation. Account creation will send email to client
    #RestClient.post(base_uri, data.to_json, {content_type: :json, accept: :json, Authorization: "Bearer #{@zoom_web_token}"})
    LOG.info("Zoom client to be created: #{data}")
  end

  def remove_user!(user_id_or_email:)
    user_path = ZOOM_API_URL + "users/#{user_id_or_email}"
    #results = RestClient.delete(user_path, {accept: :json, Authorization: "Bearer #{@zoom_web_token}"})
    LOG.info("Zoom user to delete: #{user_path}")
    #LOG.info("Results: #{results}")
  end

  def meeting_report_for(from: Date.today - 2.months, to: Date.today - 1.month)
    call(endpoint: 'metrics/meetings', params: {from: from.to_s, to: to.to_s })
  end

  def meeting_instance(meeting_id:)
    call(endpoint: "metrics/meetings/#{meeting_id}")
  end

  def dashboard_participants_for_meeting(meeting_id:)
    call(endpoint: "metrics/meetings/#{meeting_id}/participants")
  end

  def daily_report(date: Date.today - 1.month)
    call(endpoint: 'report/daily/', params: {year: date.year, month: date.month})
  end

  def users_report(from: Date.today - 2.months, to: Date.today - 1.month)
    call(endpoint: 'report/users/', params: {from: from.to_s, to: to.to_s})
  end

  def fetch_user(user_id:)
    call(endpoint: "users/#{user_id}")
  end

  def all_users
    call(endpoint: 'users/')
  end

  def meeting_participants_report(meeting_id:)
    call(endpoint: "report/meetings/#{meeting_id}/participants")
  end

  # this will send an invite to the passed in SF user's primary email to join zoom
  def add_sf_user(sf_user)
    LOG.info("SF user not found in zoom. Adding to Zoom")
    post(endpoint: 'users/', data:
         {action: 'create',
          user_info: {
            email: SalesforceSync.primary_email(sf_user),
            type: BASIC_USER_TYPE,
            first_name: sf_user.FirstName,
            last_name: sf_user.LastName,
          }
        })
  end
end
