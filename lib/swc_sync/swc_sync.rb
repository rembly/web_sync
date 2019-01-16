# frozen_string_literal: true

require 'rest-client'
require 'json'
require 'active_support/all'
require 'csv'
require_relative '../web_sync/json_web_token'
require_relative '../web_sync/mysql_connection'
require_relative '../zoom_sync'
require_relative '../salesforce_sync'

# Rate Limiting Headers
# X-Rate-Limit-Limit – Number of requests allowed in the time frame 100 requests per 60 seconds
# X-Rate-Limit-Remaining – Number of requests let in the current time frame
# X-Rate-Limit-Reset – Seconds left in the current me frame
# TODO: Abstract Rest Methods and Throttling to base class with ZoomSync
class SwcSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'swc.log'))
  HALT_CALL_QUEUE_SIGNAL = :stop
  MAX_CALLS_PER_SECOND = 0.4
  TIME_BETWEEN_CALLS = 0.4
  API_URL = "https://#{ENV['SWC_AUDIENCE']}/services/4.0/"
  FILES_PATH = ENV['BUDDY_FILE_PATH']
  CHAPTER_FILE_LOCATION = File.join(File.dirname(__FILE__), '..', 'data', 'chapter_import.json')
  # ACTION_TEAM_FILE_LOCATION = File.join(File.dirname(__FILE__), '..', 'data', 'action_team_import.json')
  BUDDY_FILES_CSV = File.join(File.dirname(__FILE__), '..', 'data', 'buddy_drive_files.csv')
  # ACTION_TEAM_MEMBERS = File.join(File.dirname(__FILE__), '..', 'data', 'action_team_members.json')
  GROUP_MEMBERS = File.join(File.dirname(__FILE__), '..', 'data', 'group_members.json')
  STATE_COORD_MEMBERS = File.join(File.dirname(__FILE__), '..', 'data', 'state_coord_members.json')
  SWC_GROUPS = File.join(File.dirname(__FILE__), '..', 'data', 'swc_groups.json')
  SWC_GROUP_OWNERS = File.join(File.dirname(__FILE__), '..', 'data', 'swc_groups_owners.json')
  SWC_SF_GROUP_MAP = File.join(File.dirname(__FILE__), '..', 'data', 'swc_sf_group_map.json')
  SWC_ACTION_TEAM_LEADERS = File.join(File.dirname(__FILE__), '..', 'data', 'swc_action_team_leaders.json')
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
    @users.present? ? @users : @users = call(endpoint: 'users', params:{activeOnly: :false})
  end

  def sf_chapters_to_import
    # for initial beta
    # WHERE Creation_Stage__c IN ('In Progress', 'Active')
    # AND Id in ('a0O0V00000bPUIR', 'a0Od000000FRaNj', 'a0Od000000ZE3aY', 'a0Od000000ZE3ad','a0Od000000Ws08z', 'a0Od000000FRaMq')
    # WHERE MALatitude__c != null AND MALongitude__c != null AND 
    sf.client.query(<<-QUERY)
      SELECT #{SalesforceSync::DEFAULT_CHAPTER_FIELDS.join(', ')}
      FROM Group__c
        WHERE Creation_Stage__c IN ('Active', 'In Progress') AND SWC_Group_ID__c = null
    QUERY
  end

  # 1 first script
  def build_ccl_chapter_import
    # selects active and in-progress chapters. # chapters = sf.ccl_chapters
    chapters = sf_chapters_to_import
    leaders = group_leaders_by_group_id
    import_string = chapters.collect { |ch| get_chapter_json_from_sf(ch, leaders) }
    File.open(CHAPTER_FILE_LOCATION, 'w') { |f| f.puts(import_string.to_json) }
  end

  # #5 - builds the mapping of SWC group to SF group for import in the SWC group admin page
  def build_swc_sf_group_map
    groups = sf.client.query('SELECT Id, SWC_Group_ID__c, Name FROM Group__c WHERE SWC_Group_ID__c <> null')
    File.open(SWC_SF_GROUP_MAP, 'w') do |f|
      f.puts({ 'group_map': groups.map { |g| { 'swl_group': g.SWC_Group_ID__c.to_i.to_s, 'thirdparty_group': g.Name } } }.to_json)
    end
  end

  # # 3 - not needed
  # def build_action_team_import
  #   action_teams = wp_client.query('SELECT * FROM wp_bp_groups WHERE parent_id = 283')
  #   action_teams_by_name = action_teams.to_a.each_with_object({}) { |team, map| map[team['name']] = team }
  #   sf_action_teams = sf.client.query('SELECT Name, Inactive__c, Leader_1__c, Leader_2__c, Leader_1__r.SWC_User_ID__c, Leader_2__r.SWC_User_ID__c FROM Action_Team__c WHERE Inactive__c = false')
  #   import_string = sf_action_teams.collect { |sf_team| get_action_team_json(sf_team, action_teams_by_name[sf_team.Name]) }
  #   File.open(ACTION_TEAM_FILE_LOCATION, 'w') { |f| f.puts(import_string.to_json) }
  # end

  # def action_team_members
  #   wp_client.query(<<-QUERY)
  #     SELECT u.id, u.user_login, u.user_nicename, u.user_email, g.name group_name, gm.user_title
  #     FROM wp_bp_groups g
  #       JOIN wp_bp_groups_members gm ON g.id = gm.group_id
  #       JOIN wp_users u ON u.id = gm.user_id
  #     WHERE parent_id = 283
  #   QUERY
  # end

  # #2 - after initial import of groups via import tool, set the SWC ID in SF
  # TODO: we could build a CSV for mass update in SF depending on API call limit..
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

  # # 1 - set action team members via JSON import file for use with import tool
  # def set_action_team_members
  #   action_members = action_team_members
  #   # Use all groups.. some 'action teams' in old community will be admin groups in new community
  #   swc_action_teams = call(endpoint: 'groups')
  #   team_names = swc_action_teams.each_with_object({}) { |team, map| map[team['name']] = team['id']; }
  #   # TODO limit by SWC ID present?
  #   sf_community_users = sf.client.query("SELECT Id, FirstName, LastName, Email, SWC_User_ID__c, CCL_Community_Username__c FROM Contact WHERE CCL_Community_Username__c <> '' AND SWC_User_ID__c <> 0")
  #   user_logins = sf_community_users.each_with_object({}) { |user, map| map[user.CCL_Community_Username__c] = user; }

  #   update = action_members.each_with_object([]) do |member, updates|
  #     # this will create a user if we don't filter SF users by those with SWC ID
  #     username = member['user_login']
  #     action_team = CGI.escape(member['group_name'])
  #     next unless user_logins.include?(username) && team_names.key?(action_team)
  #     sf_user = user_logins[username]
  #     updates << { '*_email_address': sf_user.Email.to_s.gsub('+', '%2B'), '*_username': sf_user.FirstName + ' ' + sf_user.LastName,
  #                  '*_first_name': sf_user.FirstName, '*_last_name': sf_user.LastName, 'o_groups': team_names[action_team] }
  #   end
  #   # can do multiple of the same user
  #   File.open(ACTION_TEAM_MEMBERS, 'w') { |f| f.puts(update.to_json) }
  # end

  # def set_action_team_admins
  #   action_leaders = sf.client.query("SELECT Name, Inactive__c, Leader_1__c, Leader_2__c, Leader_1__r.SWC_User_ID__c, Leader_2__r.SWC_User_ID__c FROM Action_Team__c WHERE Inactive__c = false")
  #   swc_action_teams = call(endpoint: 'groups', params: { categoryId: ACTION_TEAM_CATEGORY })
  #   team_names = swc_action_teams.each_with_object({}) { |team, map| map[team['name']] = team['id']; }

  #   action_leaders.each do |team|
  #     group_id = team_names[CGI.escape(team.Name)]
  #     next unless group_id.present?
  #     uri = URI.join(API_URL, "groups/#{group_id}/members").to_s
  #     if team&.Leader_1__r&.SWC_User_ID__c
  #       res = RestClient.post(uri, { userId: team.Leader_1__r.SWC_User_ID__c.to_i, invited: true, status: 2,
  #         notifications: {members: 1, photos: 1, files: 1, forums: 1, videos: 1, events: 1}}.to_json,  content_type: :json, Authorization: "Bearer #{swc_token}") 
  #       LOG.info("Created User #{team.Leader_1__r.SWC_User_ID__c.to_i.to_s} for #{team.Name}: #{res}")
  #       sleep TIME_BETWEEN_CALLS
  #     end
  #     if team&.Leader_2__r&.SWC_User_ID__c
  #       res = RestClient.post(uri, { userId: team.Leader_2__r.SWC_User_ID__c.to_i, invited: true, status: 2,
  #         notifications: {members: 1, photos: 1, files: 1, forums: 1, videos: 1, events: 1}}.to_json, content_type: :json, Authorization: "Bearer #{swc_token}") 
  #       LOG.info("Created User #{team.Leader_2__r.SWC_User_ID__c.to_i.to_s} for #{team.Name}: #{res}")
  #       sleep TIME_BETWEEN_CALLS
  #     end
  #   end
  # end

  def sf_chapters_to_import
    sf.client.query(<<-QUERY)
      SELECT #{SalesforceSync::DEFAULT_CHAPTER_FIELDS.join(', ')}
      FROM Group__c
        WHERE Creation_Stage__c IN ('In Progress') AND SWC_Group_ID__c = null
        AND Id NOT IN ('a0O0V00000bPUIR', 'a0Od000000FRaNj', 'a0Od000000ZE3aY', 'a0Od000000ZE3ad','a0Od000000Ws08z', 'a0Od000000FRaMq')
    QUERY
  end

  # set group members via JSON import file for use with import tool
  # TODO: This will be set by SF?
  def set_group_members
    group_leaders_id = "1767"
    regional_coord_id = "946"
    #users from sf w swc
    group_members = sf.client.query("SELECT Id, Email, FirstName, LastName, Group_Leader_del__c, SWC_User_ID__c, Group_del__r.SWC_Group_ID__c,
      Group_del__c, Is_Regional_Coordinator__c FROM Contact WHERE SWC_User_ID__c <> null AND Group_del__c <> null AND Group_del__r.SWC_Group_ID__c <> null")

    update = group_members.each_with_object([]) do |contact, updates|
      # this will create a user if we don't filter SF users by those with SWC ID
      next unless contact&.Group_del__r&.SWC_Group_ID__c.present? 

      group_ids = [contact.Group_del__r.SWC_Group_ID__c.to_i.to_s]
      group_ids << group_leaders_id if contact.Group_Leader_del__c
      group_ids << regional_coord_id if contact.Is_Regional_Coordinator__c

      updates << { '*_email_address': contact.Email.to_s.gsub('+', '%2B'), '*_username': contact.FirstName + ' ' + contact.LastName,
                   '*_first_name': contact.FirstName, '*_last_name': contact.LastName, 
                   'o_groups': group_ids.join(',') }
    end
    # can do multiple of the same user
    File.open(GROUP_MEMBERS, 'w') { |f| f.puts(update.to_json) }
  end

  def set_state_coord
    state_coord_id = "999"

    group_members = sf.client.query("SELECT Id, Email, FirstName, LastName, Group_Leader_del__c, SWC_User_ID__c, Group_del__r.SWC_Group_ID__c,
      Group_del__c, Is_Regional_Coordinator__c, Is_State_Coordinator__c FROM Contact WHERE SWC_User_ID__c <> null AND Group_del__c <> null AND Group_del__r.SWC_Group_ID__c <> null AND Is_State_Coordinator__c = true")

    update = group_members.each_with_object([]) do |contact, updates|
      # this will create a user if we don't filter SF users by those with SWC ID
      next unless contact&.Group_del__r&.SWC_Group_ID__c.present? 

      updates << { '*_email_address': contact.Email.to_s.gsub('+', '%2B'), '*_username': contact.FirstName + ' ' + contact.LastName,
                   '*_first_name': contact.FirstName, '*_last_name': contact.LastName, 
                   'o_groups': '999' }
    end
    # can do multiple of the same user
    File.open(STATE_COORD_MEMBERS, 'w') { |f| f.puts(update.to_json) }
  end

  # map of group ID to ONE group leader # TODO: only one for new chapters
  def group_leaders_by_group_id
    group_leaders = sf.client.query("SELECT Id, Email, FirstName, LastName, Group_Leader_del__c, SWC_User_ID__c, Group_del__r.SWC_Group_ID__c,
      Group_del__c FROM Contact WHERE Group_Leader_del__c = True AND SWC_User_ID__c <> null AND Group_del__c <> null AND Group_del__r.SWC_Group_ID__c = null")

    leaders_by_group = group_leaders.each_with_object({}) do |leader, map|
      if leader&.Group_del__c.present? && leader.SWC_User_ID__c.present?
        map[leader.Group_del__c] = leader
      end
    end

    leaders_by_group
  end

  def get_chapter_json_from_sf(ch, leaders)
    owner = leaders.key?(ch.Id) ? leaders[ch.Id].SWC_User_ID__c.to_i.to_s : GROUP_DEFAULT_OWNER.to_s

    { '*_name': ch.Name, '*_description': GROUP_DESCRIPTION_TEXT % ch.Name, '*_category_id': GROUP_CHAPTER_CATEGORY,
      '*_owner_user_id': owner, 'o_access_level': ch.Creation_Stage__c == 'In-Active' ? '3' : '1',
      'o_address': ",,#{ch.City__c},#{ch.State__c},,#{!ch.Country__c.nil? ? ch.Country__c : 'USA'}",
      'o_news': GROUP_NEWS_TEXT % (ch.Group_Email__c || 'chapter@ccl.org'),
      'o_content_forums': '2', 'o_content_events': '2', 'o_content_photos': '0',
      'o_content_videos': '0', 'o_content_files': '1', 'o_content_members': '1' }
  end

  # def get_action_team_json(sf_team, wp_action_team)
  #   wp_action_team ||= {}
  #   owner = sf_team&.Leader_1__r&.SWC_User_ID__c || sf_team&.Leader_2__r&.SWC_User_ID__c || GROUP_DEFAULT_OWNER
  #   status = wp_action_team && wp_action_team.dig('status') == 'private' ? '2' : '1'

  #   { '*_name': sf_team.Name, '*_description': wp_action_team.dig('description') || sf_team.Name,
  #     '*_category_id': ACTION_TEAM_CATEGORY, '*_owner_user_id': owner.to_i.to_s, 'o_access_level': status,
  #     'o_content_forums': '2', 'o_content_events': '2', 'o_content_photos': '1',
  #     'o_content_videos': '1', 'o_content_files': '1', 'o_content_members': '1' }
  # end

  # CAUTION run this only after confirming you're pointing at staging and not production
  def reset_staging
    return false unless ENV['ENVIRONMENT'] == 'development' && API_URL.include?('stage')
    groups_to_delete = call(endpoint: 'groups')
    # groups_to_delete = groups_to_delete.select{|g| ['4', '5', '6'].include?(g['categoryId'])}
    # TODO: group member records get cleared too right?
    # groups_to_delete.each{|g| send_delete(endpoint: "groups/#{g['id']}");sleep MAX_CALLS_PER_SECOND}

    # delete users with userId > 33 AND <  15193
    all_users = call(endpoint: 'users', params:{activeOnly: false})
    users_to_remove = all_users.select{|u| u['userId'].to_i > 1092}
    # lets get all files so that we're not re-fetching for each user
    files = call(endpoint: 'files')
    files_by_user = files.group_by{|f| f['userId']}
    # for each user remove their files
    users_to_remove.each do |user|
      # delete files
      files_by_user[user['userId']].each{|file| send_delete(endpoint: "files/#{file['id']}");sleep MAX_CALLS_PER_SECOND} if files_by_user[user['userId']].present?
      
      send_delete(endpoint: "users/#{user['userId']}")
      sleep MAX_CALLS_PER_SECOND
    end
    # TODO - upload empty group to SF group mapping?
  end

  def buddy_drive_files
    wp_client.query(<<-QUERY)
      SELECT u.ID as userId, u.user_login, u.user_email as email, wp.guid as path, wp.post_title as title, wp.id as post_id,
        wp.post_content as description, post_mime_type as mime_type, wp.post_status, g.name as group_name
      FROM wp_users u JOIN wp_posts wp ON wp.post_author = u.ID
      LEFT JOIN wp_postmeta wm on wm.post_id = wp.id AND wm.meta_key = '_buddydrive_sharing_groups'
      LEFT JOIN wp_bp_groups g ON g.id = wm.meta_value
      WHERE post_type = 'buddydrive-file'
    QUERY
  end

  def active_members_on_old_community
    wp_client.query(<<-QUERY)
      SELECT  u.user_login, u.user_email, um.meta_key, um.meta_value, cast(um.meta_value as datetime)
      FROM `wp_usermeta` um
      JOIN wp_users u on u.ID = um.user_ID
      WHERE meta_key = 'last_activity' AND cast(um.meta_value as datetime) >= DATE_ADD(Now(), INTERVAL - 4 MONTH)
    QUERY
  end

  # 6
  def upload_files
    # CSV.foreach(BUDDY_FILES_CSV) { |row| upload_file(row[1], row[2], row[3], row[4]) }
    sf_community_users = sf.client.query("SELECT Id, FirstName, LastName, Email, SWC_User_ID__c, CCL_Community_Username__c FROM Contact WHERE CCL_Community_Username__c <> '' AND SWC_User_ID__c <> 0")
                           .each_with_object({}) { |user, map| map[user.CCL_Community_Username__c] = user.SWC_User_ID__c }
    sf_groups = sf.client.query('SELECT Id, SWC_Group_ID__c, Name FROM Group__c WHERE SWC_Group_ID__c <> null')
                  .each_with_object({}) { |group, map| map[CGI.escape(group.Name.downcase)] = group.SWC_Group_ID__c }
    all_groups = call(endpoint: 'groups').each_with_object(sf_groups){|grp, map| map[grp['name'].downcase] = grp['id']}
    missing_groups = Set.new
    upload_count = 0
    buddy_drive_files.each do |buddy_file|
      # find the user and group
      user_id = sf_community_users[buddy_file['user_login']].to_i.to_s
      group_id = all_groups[CGI.escape(buddy_file['group_name'].to_s.downcase)]&.to_i&.to_s

      if buddy_file['group_name'].blank? || (buddy_file['group_name'].present? && group_id.present?)
        upload_file(buddy_file, user_id, group_id)
        sleep MAX_CALLS_PER_SECOND
        upload_count += 1
      else
        LOG.error("Couldn't find group #{buddy_file['group_name']} for file: #{buddy_file}")
        missing_groups << buddy_file['group_name']
      end
    end

    LOG.error("***Missing groups: " + missing_groups.to_a.to_s)
    LOG.info("***Uploaded: #{upload_count} files")
  end

  def upload_file(file, user_id, group_id)
    if user_id.to_i.nonzero?
      begin
        filename = File.basename(URI.parse(file['path'])&.path)
        upload = File.join(FILES_PATH, filename)
        uri = URI.join(API_URL, group_id.present? ? "groups/#{group_id}/files" : 'files').to_s
        # LOG.info("Uploading #{group_id.present? ? 'Group' : ''} File #{file}, URI: #{uri}, User: #{user_id}, Group: #{group_id}, File: #{upload}")
        RestClient.post(uri, { file: upload, title: file['title'], description: file['description'],
                               public: false, userId: user_id, categoryId: '0' }, Authorization: "Bearer #{swc_token}")
      rescue RestClient::ExceptionWithResponse => e
        return handle_response(e.response)
      rescue URI::InvalidURIError => e
        LOG.error("Could not upload #{group_id.present? ? 'Group' : ''} File #{file}, URI: #{uri}, User: #{user_id}, Group: #{group_id}, File: #{upload}")
        LOG.error("Exception: #{e.message}")
      end
    else
      LOG.error("User #{user_id} not found for file upload #{file}")
    end
  end

  def find_user_id_from_email(email)
    get_users.find { |u| u['emailAddress'] == email }.try(:dig, 'userId')
  end

  # NOTE: unable to set group owner via import tool at this time
  def build_group_owner_import
    leaders_by_group = group_leaders_by_group_id
    # get all swc groups with system user as owner
    swc_groups = call(endpoint: 'groups')
    File.open(SWC_GROUPS, 'w') { |f| f.puts swc_groups.to_json } # save latest group list
    updates = []
    swc_groups.select { |g| g['ownerId'] == GROUP_DEFAULT_OWNER.to_s }.each do |group|
      if leaders_by_group.key?(group['id'])
        updates << { 'o_group_id': group['id'], '*_name': group['name'], '*_description': group['description'],
                     '*_category_id': group['categoryId'], '*_owner_user_id': leaders_by_group[group['id']].SWC_User_ID__c.to_i.to_s }
      end
    end
    File.open(SWC_GROUP_OWNERS, 'w') { |f| f.puts(updates.to_json) }
  end

  # def build_action_team_admin_export
  #   action_teams = call(endpoint:'groups', params: {categoryId: 5})
  #   action_team_ids = action_teams.map{|r| r['id']}
  #   action_team_members = action_team_ids.map{|team_id| call(endpoint: "groups/#{team_id}/members", params: {embed: 'user'})}
  #   action_team_admins = action_team_members.flatten.select{|member| member['status'].to_i > 1}.map{|admin| admin['user']}

  #   update = action_team_admins.uniq.each_with_object([]) do |admin, updates|
  #     updates << { '*_email_address': admin['emailAddress'], '*_username': admin['username'],
  #                  '*_first_name': admin['firstName'], '*_last_name': admin['lastName'], 
  #                  'o_groups': '1878' }
  #   end
  #   # can do multiple of the same user
  #   File.open(SWC_ACTION_TEAM_LEADERS, 'w') { |f| f.puts(update.to_json) }
  # end

  def join_user_to_group
    user_id = 26;
    group_id = 1772;

    uri = URI.join(API_URL, "groups/#{group_id.to_s}/members")

    data = {userId: user_id, invited: true, status: 1, notifications: {members: 1, photos: 1, files: 1, forums: 1, videos: 1, events: 1}, permissions: {members: 1, photos: 1, files: 1, forums: 1, videos: 1, events: 0}}.to_json
    res = RestClient.post(uri, data, content_type: :json, Authorization: "Bearer #{swc_token}")
  end

  # get action teams: res = sc.call(endpoint:'groups', params: {categoryId: 5})
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

  def send_delete(endpoint:, params: {})
    base_uri = URI.join(API_URL, endpoint).to_s
    begin
      RestClient.delete(base_uri, Authorization: "Bearer #{swc_token}")
      LOG.info("Deleted: #{endpoint}")
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
      results = JSON.parse(response)
      return gather_pages?(response) ? merge_results(results, get_next_page(response)) : results
    else
      # TODO: potentially handle rate limit
      LOG.error("FAILED request #{response.request}: MESSAGE: #{JSON.parse(response)}")
      return JSON.parse(response)
    end
   end

  # gather pages if there is a next_page token and the result set contains participants
  def gather_pages?(response)
    response.headers.key?(:link)
  end

  # get next page by re-sending same request but with next page token. This will block for max api call rate duration
  def get_next_page(response)
    next_page_url = response.headers[:link].match(/^<([^>]*)>; rel=\"next/)
    request_uri = URI.parse(next_page_url.captures.first)
    endpoint = [request_uri.path.split('/').last, request_uri.query].join('?')
    sleep TIME_BETWEEN_CALLS
    call(endpoint: endpoint)
  end

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
        call_request.call()
        sleep MAX_CALLS_PER_SECOND
      end

      LOG.info('SWC sync queue halt signal received, ending thread')
    end
  end
end

def run_delete 
  sc = SwcSync.new
  groups = sc.call(endpoint: 'groups', params: { categoryId: '4,5,6' }).select{|g| g['id'].to_i >= 40}
  # groups.each{|g| sc.queue_delete(endpoint: "groups/#{g['id']}")}
  groups.each{|g| sc.send_delete(endpoint: "groups/#{g['id']}"); sleep MAX_CALLS_PER_SECOND}
end