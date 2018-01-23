require 'jwt'
require 'active_support/all'

class JsonWebToken
  EXPIRATION_SECONDS = 86400 # 1 day
  ZOOM_API_KEY = ENV['ZOOM_API_KEY']
  ZOOM_API_SECRET = ENV['ZOOM_API_SECRET']

  def self.zoom_token
    p "Fetching zoom token"
    payload = {iss: ZOOM_API_KEY, exp: EXPIRATION_SECONDS.seconds.from_now.to_i}
    JWT.encode(payload, ZOOM_API_SECRET)
  end
end