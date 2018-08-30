# frozen_string_literal: true

require 'rest-client'
require 'json'
require 'active_support/all'
require_relative 'web_sync/json_web_token'
require_relative 'web_sync/mysql_connection'
require_relative './zoom_sync'
require_relative 'salesforce_sync'
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
  CHAPTER_FILE_LOCATION = File.join(File.dirname(__FILE__), '..', 'data', 'chapter_import.json')
  ACTION_TEAM_FILE_LOCATION = File.join(File.dirname(__FILE__), '..', 'data', 'action_team_import.json')
  BUDDY_FILES_CSV = File.join(File.dirname(__FILE__), '..', 'data', 'buddy_drive_files.csv')
  ACTION_TEAM_MEMBERS = File.join(File.dirname(__FILE__), '..', 'data', 'action_team_members.json')
  DRIVE_COLUMNS = %i[id email path title description mime_type].freeze
  DEFAULT_CATEGORY = '1'
  SWC_CONTACT_FIELDS = %w[Email FirstName LastName Region__c Group_del__c SWC_Create_User__c SWC_Chapter_Status__c SWC_User_ID__c SWC_Regional_Coordinator__c SWC_Staff__c SWC_State_Coordinator__c SWC_Liaison__c SWC_Group_Leader__c Country_Full_Name__c Group_del__r.SWC_Group_ID__c Group_Leader_del__c].freeze
  SWC_CONTACT_IMPORT_COLUMNS = %w[*_email_address *_username *_first_name *_last_name o_date_joined o_language o_signature o_segments o_avatar_file_location o_groups o_privacy_send_mail o_privacy_profile_posts o_privacy_profile_posts_details o_privacy_my_files o_privacy_my_photos o_privacy_my_videos o_notification_emails o_notification_profile o_notification_photos o_notification_multimedia o_notification_files	o_notification_blogs o_notification_events o_notification_groups o_notification_reviews o_notification_forums o_notification_likes o_notification_mentions o_privacy_About_Me o_privacy_CCL_Info	o_privacy_Address	o_privacy_Phone o_privacy_Email o_privacy_Social_Media o_privacy_My_Interests].freeze
  SWC_GROUP_IMPORT_COLUMNS = %w[o_group_id *_name *_description *_category_id *_owner_user_id o_access_level o_address o_invite_message o_welcome_message o_news o_content_forums o_content_invite o_content_events o_content_photos o_content_videos o_content_files o_content_members o_content_blogs o_photo_location].freeze

  GROUP_DESCRIPTION_TEXT = "Welcome to Citizens\xE2\x80\x99 Climate Lobby %s! We work within our community and our local members of Congress towards enacting a big, national solution to climate change. We work by building relationships and finding common ground. We welcome anyone in the area who likes this approach to join us."
  GROUP_INVITE_TEXT = "Sign up to get started with CCL. We\xE2\x80\x99ll connect you with your local group, and provide you with information about the training and resources you need."
  GROUP_NEWS_TEXT = "Most chapters meet monthly on or near the second Saturday of the month. Contact %s to get details on this chapter's meeting schedule."
  GROUP_CHAPTER_CATEGORY = 4
  GROUP_DEFAULT_OWNER = 1
  ACTION_TEAM_CATEGORY = 5

  # queue for rate_limited api calls
  attr_reader :call_queue
  attr_reader :last_response
  attr_accessor :queue_consumer
  attr_accessor :swc_token
  attr_accessor :users
  attr_accessor :sf
  attr_accessor :wp_client

  def initialize
    @swc_token = JsonWebToken.swc_token
    @call_queue = Queue.new
    @queue_consumer = start_request_queue_consumer
    @sf = SalesforceSync.new
    @wp_client = MysqlConnection.get_connection
  end

  def get_users
    @users.present? ? @users : @users = call(endpoint: 'users')
  end

  def get_sf_contacts
    # WHERE LastName = 'Hermsen' AND Is_CCL_Supporter__c = True
    contacts = @sf.client.query(<<-QUERY)
      SELECT #{SWC_CONTACT_FIELDS.join(', ')}
      FROM Contact
    QUERY
  end

  def build_ccl_member_import(query); end

  def build_ccl_chapter_import
    # selects active and in-progress chapters. TODO
    chapters = sf.ccl_chapters
    import_string = chapters.collect(&method(:get_chapter_json_from_sf))
    File.open(CHAPTER_FILE_LOCATION, 'w') { |f| f.puts(import_string.to_json) }
  end

  def build_action_team_import
    action_teams = wp_client.query('SELECT * FROM wp_bp_groups WHERE parent_id = 283')
    import_string = action_teams.collect(&method(:get_chapter_json_from_sql))
    File.open(ACTION_TEAM_FILE_LOCATION, 'w') { |f| f.puts(import_string.to_json) }
  end

  def action_team_members
    wp_client.query(<<-QUERY)
      SELECT u.id, u.user_login, u.user_nicename, u.user_email, g.name group_name
      FROM wp_bp_groups g
        JOIN wp_bp_groups_members gm ON g.id = gm.group_id
        JOIN wp_users u ON u.id = gm.user_id
      WHERE parent_id = 283
    QUERY
  end

  # after initial import of groups via import tool, set the SWC ID in SF
  # TODO: we could build a CSV for mass update depending on API call limit..
  def set_group_id_in_sf
    sw_groups = call(endpoint: 'groups')
    by_name = sw_groups.group_by { |grp| grp['name'] }
    sf.ccl_chapters(%w[Id Name SWC_Group_ID__c]).each do |ch|
      if by_name.key?(CGI.escape(ch.Name)) && ch.SWC_Group_ID__c.blank?
        ch.SWC_Group_ID__c = by_name[CGI.escape(ch.Name)].first['id'].to_i
        ch.save
      else
        LOG.info("Group from SF not found in SWC: #{ch}")
      end
    end
  end

  # TODO: could also be done via Import Tool
  def set_action_team_members
    action_members = action_team_members
    swc_action_teams = call(endpoint: 'groups', params: { categoryId: ACTION_TEAM_CATEGORY })
    team_names = swc_action_teams.each_with_object({}) { |team, map| map[team['name']] = team['id']; }
    sf_community_users = sf.client.query("SELECT Id, FirstName, LastName, Email, SWC_User_ID__c, CCL_Community_Username__c FROM Contact WHERE CCL_Community_Username__c <> ''")
    # user_logins = sf_community_users.map(&:CCL_Community_Username__c)
    # user_logins = sf_community_users.inject({}){ |map, user| map[user.CCL_Community_Username__c] = user.SWC_User_ID__c; map }
    user_logins = sf_community_users.each_with_object({}) { |user, map| map[user.CCL_Community_Username__c] = user; }
    # sw_users = sc.call(endpoint: 'users', params: {'fields': 'userId, emailAddress, username, firstName, lastName'})
    # sw_user_map = sw_users.inject({}){|map, user| map[user['userId'].to_i] = user; map}

    update = action_members.each_with_object([]) do |member, updates|
      # can we find them in SF, can we find the action team SW ID? do they have a SW ID in SF?
      username = member['user_login']
      action_team = CGI.escape(member['group_name'])
      next unless user_logins.include?(username) && team_names.key?(action_team)
      sf_user = user_logins[username]
      updates << { '*_email_address': sf_user.Email.gsub('+', '%2B'), '*_username': sf_user.FirstName + '_' + sf_user.LastName,
                   '*_first_name': sf_user.FirstName, '*_last_name': sf_user.LastName, 'o_groups': team_names[action_team] }
    end
    # can do multiple of the same user
    File.open(ACTION_TEAM_MEMBERS, 'w') { |f| f.puts(update.to_json) }
  end

  def get_chapter_json_from_sf(ch)
    { '*_name': ch.Name, '*_description': GROUP_DESCRIPTION_TEXT % ch.Name, '*_category_id': GROUP_CHAPTER_CATEGORY,
      '*_owner_user_id': GROUP_DEFAULT_OWNER, 'o_access_level': ch.Creation_Stage__c == 'In-Active' ? '3' : '1',
      'o_address': ",,#{ch.City__c}, #{ch.State__c},, #{!ch.Country__c.nil? ? ch.Country__c : 'USA'}",
      'o_news': GROUP_NEWS_TEXT % (ch.Group_Email__c || 'chapter@ccl.org'),
      'o_content_forums': '1', 'o_content_invite': '2', 'o_content_events': '0', 'o_content_photos': '2',
      'o_content_videos': '1', 'o_content_files': '1', 'o_content_members': '2' }
  end

  def get_chapter_json_from_sql(grp)
    { '*_name': grp['name'], '*_description': grp['description'].present? ? grp['description'] : grp['name'],
      '*_category_id': ACTION_TEAM_CATEGORY, '*_owner_user_id': GROUP_DEFAULT_OWNER,
      'o_access_level': grp['status'] == 'public' ? '1' : '2',
      'o_content_forums': '1', 'o_content_invite': '2', 'o_content_events': '0', 'o_content_photos': '1',
      'o_content_videos': '1', 'o_content_files': '1', 'o_content_members': '2' }
  end

  def upload_files
    CSV.foreach(BUDDY_FILES_CSV) { |row| upload_file(row[1], row[2], row[3], row[4]) }
  end

  def upload_file(email, url, title, description)
    id = find_user_id_from_email(email)
    if id.present?
      filename = File.basename(URI.parse(url)&.path)
      file = File.new(File.join(FILES_PATH, filename), 'rb')
      begin
        RestClient.post(URI.join(API_URL, 'files').to_s, { file: file, title: title, description: description,
                                                           public: false, userId: id, categoryId: DEFAULT_CATEGORY }, Authorization: "Bearer #{swc_token}")
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