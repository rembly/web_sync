# frozen_string_literal: true

require 'rest-client'
require 'jwt'
require 'active_support/all'

# Generate token for interacting with Zoom API
class JsonWebToken
  EXPIRATION_SECONDS = 86_400 # 1 day
  ZOOM_API_KEY = ENV['ZOOM_API_KEY']
  ZOOM_API_SECRET = ENV['ZOOM_API_SECRET']
  SWC_TOKEN_URL = 'http://cclobby.smallworldlabs.com/services/4.0/token'

  def self.zoom_token
    p 'Fetching zoom token'
    payload = { iss: ZOOM_API_KEY, exp: EXPIRATION_SECONDS.seconds.from_now.to_i }
    JWT.encode(payload, ZOOM_API_SECRET)
  end

  def self.swc_token
    exp = (Time.now + 2.minutes).to_i
    iat = Time.now.to_i
    payload = { iss: ENV['SWC_APP_ID'], exp: 120.seconds.from_now.to_i, iat: Time.now.to_i, sub: ENV['SWC_USER_ID'],
                aud: 'cclobby.smallworldlabs.com', scope: 'create delete read update' }
    jwt = JWT.encode(payload, ENV['SWC_SECRET'])

    response = RestClient.post(SWC_TOKEN_URL, { grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                                                assertion: jwt }, content_type: 'application/x-www-form-urlencoded')
    JSON.parse(response.body).dig('access_token')
  end
end
