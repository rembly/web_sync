require 'rest-client'
require 'json'
require 'active_support/all'
# require 'web_sync/json_web_token'
# require File.join(File.dirname(__FILE__), 'lib', 'web_sync')
require File.join(File.dirname(__FILE__), 'web_sync', 'json_web_token')

# Time.now.iso8601 - for date/time format
# Date.today.to_s - for date only format

ZOOM_API_URL = 'https://api.zoom.us/v2/'
# todo
ZOOM_WEB_TOKEN = JsonWebToken.zoom_token

def test
  response = RestClient.get('wttr.in/68506')
  p JSON.parse(response)
end

def call(endpoint:, params: {})
  base_uri = URI.join(ZOOM_API_URL, endpoint).to_s
  params = params.merge({access_token: ZOOM_WEB_TOKEN})
  response = RestClient.get(base_uri, {params: params})
  JSON.parse(response)
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

def meeting_participants_report(meeting_id:)
  call(endpoint: "report/meetings/#{meeting_id}/participants")
end

