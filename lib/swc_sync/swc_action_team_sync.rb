# frozen_string_literal: true
require 'active_support/all'
require 'pry'
require_relative '../web_sync/json_web_token'
require_relative '../web_sync/mysql_connection'
require_relative '../web_sync/throttled_api_client'
require_relative '../salesforce_sync'

class SwcActionTeamSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'swc_action_team_sync.log'))
  MEMBER_MAP = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'swc_action_team_members.log'))
  ACTION_TEAM_FILE_LOCATION = File.join(File.dirname(__FILE__), '..', '..', 'data', 'action_team_import.json')
  ACTION_TEAM_MEMBERS = File.join(File.dirname(__FILE__), '..', '..', 'data', 'action_team_members.json')
  GROUP_CHAPTER_CATEGORY = 4
  GROUP_DEFAULT_OWNER = 1
  ACTION_TEAM_CATEGORY = 5

  attr_accessor :api
  attr_accessor :sf
  attr_accessor :wp
  attr_accessor :user_map

  ACTION_TEAM_MAP = {
    'group-leaders' => 1767, 'regional-coordinators' => 946, 'liaisons-1475069368' => 998,
    'ccl-visuals-graphics-art-and-more' => 960,
    'clr-caucus' => 965, # sub group???? consevative media
    'presenters-schedulers' => 973, 'team-oil' => 978, 'agriculture-team' => 968, 'rural-electric-cooperatives' => 974,
    'rotary-service-clubs' => 948, 'climate-change-national-security' => 962, 'climate-peer-support' => 972,
    'coal-country-climate-heroes-578105675' => 964, 'envoys' => 1818, 'state-carbon-taxes' => 976,
    'unitarian-universalists' => 979, 'social-media' => 975, 'climate-and-healthcare-team' => 961,
    'spanish-language' => 995, 'catholics' => 958, 'ski-and-outdoor-industry' => 984, 'bahai' => 956,
    'team-ocean' => 977, 'group-development-coaches' => 1769, 'trainers' => 1770, 'motivational-interviewing-738232779' => 970,
    '100-faith-leaders' => 967, 'endorsement-project' => 1771, 'labor-outreach' => 969,
    'engaging-youth' => 988, 'environmental-justice' => 953, # group rename
    'lds-mormon' => 954, 'presbyterians' => 997, 'business-climate-leaders' => 986, 'action-team-leaders' => 1878,
    'higher-education' => 949, 'jewish-action-team' => 955, 'biking-for-climate-action' => 993, # group rename
    'print-media' => 992, 'progressive-outreach' => 994, 'quakers' => 991, 'broadcast-media' => 963,
    'climate-reality-leadership-corp' => 989, 'evangelical-christian-action-team' => 983, # group rename
    'strategic-planning' => 985, 'episcopal-action-team' => 981, # group rename 'chinese-action-team' => 980, #group rename
    'lgbtqa-climate' => 1880,
  } 

  def initialize
    @api = ThrottledApiClient.new(api_url: "https://#{ENV['SWC_AUDIENCE']}/services/4.0/",
                                logger: LOG, token_method: JsonWebToken.method(:swc_token))
    @sf = SalesforceSync.new
    @wp = MysqlConnection.get_connection
    @user_map = get_user_map
  end

  def get_users
    @users.present? ? @users : @users = call(endpoint: 'users', params:{activeOnly: :false})
  end

  def action_team_members
    wp.query(<<-QUERY)
      SELECT u.id, u.user_login, u.user_nicename, u.user_email, g.name group_name, gm.user_title, g.slug
      FROM wp_bp_groups g
        JOIN wp_bp_groups_members gm ON g.id = gm.group_id
        JOIN wp_users u ON u.id = gm.user_id
      WHERE parent_id = 283
    QUERY
  end

  def get_team_id(team_names, row)
    return ACTION_TEAM_MAP[row['slug'].to_s] if ACTION_TEAM_MAP.key?(row['slug'].to_s)
    action_team = CGI.escape(row['group_name'])
    return team_names[action_team] if team_names.key?(action_team)
  end

  # 1 - set action team members via JSON import file for use with import tool
  def set_action_team_members
    action_members = action_team_members
    # Use all groups.. some 'action teams' in old community will be admin groups in new community
    swc_action_teams = api.call(endpoint: 'groups')
    team_names = swc_action_teams.each_with_object({}) { |team, map| map[team['name']] = team['id']; }
    # TODO limit by SWC ID present?
    # sf_community_users = sf.client.query("SELECT Id, FirstName, LastName, Email, SWC_User_ID__c, CCL_Community_Username__c FROM Contact WHERE CCL_Community_Username__c <> '' AND SWC_User_ID__c <> 0")
    # user_logins = sf_community_users.each_with_object({}) { |user, map| map[user.CCL_Community_Username__c] = user; }
    
    update = action_members.each_with_object([]) do |member, updates|
      # this will create a user if we don't filter SF users by those with SWC ID
      username = member['user_login']
      # action_team = CGI.escape(member['group_name'])
      team_id = get_team_id(team_names, member)
      next unless user_map.include?(username) && team_id.present?
      sf_user = user_map[username]
      updates << { '*_email_address': sf_user.Email.to_s.gsub('+', '%2B'), '*_username': sf_user.FirstName + ' ' + sf_user.LastName,
                  '*_first_name': sf_user.FirstName, '*_last_name': sf_user.LastName, 'o_groups': team_id }
    end
    # can do multiple of the same user
    File.open(ACTION_TEAM_MEMBERS, 'w') { |f| f.puts(update.to_json) }
  end

  def set_action_team_admins
    action_leaders = sf.client.query("SELECT Name, Inactive__c, Leader_1__c, Leader_2__c, Leader_1__r.SWC_User_ID__c, Leader_2__r.SWC_User_ID__c FROM Action_Team__c WHERE Inactive__c = false")
    swc_action_teams = api.call(endpoint: 'groups', params: { categoryId: ACTION_TEAM_CATEGORY })
    team_names = swc_action_teams.each_with_object({}) { |team, map| map[team['name']] = team['id']; }

    action_leaders.each do |team|
      group_id = team_names[CGI.escape(team.Name)]
      next unless group_id.present?
      uri = URI.join(API_URL, "groups/#{group_id}/members").to_s
      if team&.Leader_1__r&.SWC_User_ID__c
        res = RestClient.post(uri, { userId: team.Leader_1__r.SWC_User_ID__c.to_i, invited: true, status: 2,
          notifications: {members: 1, photos: 1, files: 1, forums: 1, videos: 1, events: 1}}.to_json,  content_type: :json, Authorization: "Bearer #{swc_token}") 
        LOG.info("Created User #{team.Leader_1__r.SWC_User_ID__c.to_i.to_s} for #{team.Name}: #{res}")
        sleep TIME_BETWEEN_CALLS
      end
      if team&.Leader_2__r&.SWC_User_ID__c
        res = RestClient.post(uri, { userId: team.Leader_2__r.SWC_User_ID__c.to_i, invited: true, status: 2,
          notifications: {members: 1, photos: 1, files: 1, forums: 1, videos: 1, events: 1}}.to_json, content_type: :json, Authorization: "Bearer #{swc_token}") 
        LOG.info("Created User #{team.Leader_2__r.SWC_User_ID__c.to_i.to_s} for #{team.Name}: #{res}")
        sleep TIME_BETWEEN_CALLS
      end
    end
  end

  def build_action_team_admin_export
    action_teams = api.call(endpoint:'groups', params: {categoryId: 5})
    action_team_ids = action_teams.map{|r| r['id']}
    action_team_members = action_team_ids.map{|team_id| call(endpoint: "groups/#{team_id}/members", params: {embed: 'user'})}
    action_team_admins = action_team_members.flatten.select{|member| member['status'].to_i > 1}.map{|admin| admin['user']}

    update = action_team_admins.uniq.each_with_object([]) do |admin, updates|
      updates << { '*_email_address': admin['emailAddress'], '*_username': admin['username'],
                   '*_first_name': admin['firstName'], '*_last_name': admin['lastName'], 
                   'o_groups': '1878' }
    end
    # can do multiple of the same user
    File.open(SWC_ACTION_TEAM_LEADERS, 'w') { |f| f.puts(update.to_json) }
  end

  def get_action_team_json(sf_team, wp_action_team)
    wp_action_team ||= {}
    owner = sf_team&.Leader_1__r&.SWC_User_ID__c || sf_team&.Leader_2__r&.SWC_User_ID__c || GROUP_DEFAULT_OWNER
    status = wp_action_team && wp_action_team.dig('status') == 'private' ? '2' : '1'

    { '*_name': sf_team.Name, '*_description': wp_action_team.dig('description') || sf_team.Name,
      '*_category_id': ACTION_TEAM_CATEGORY, '*_owner_user_id': owner.to_i.to_s, 'o_access_level': status,
      'o_content_forums': '2', 'o_content_events': '2', 'o_content_photos': '1',
      'o_content_videos': '1', 'o_content_files': '1', 'o_content_members': '1' }
  end

  def active_members_on_old_community
    wp.query(<<-QUERY)
      SELECT  u.user_login, u.user_email, um.meta_key, um.meta_value, cast(um.meta_value as datetime)
      FROM `wp_usermeta` um
      JOIN wp_users u on u.ID = um.user_ID
      WHERE meta_key = 'last_activity' AND cast(um.meta_value as datetime) >= DATE_ADD(Now(), INTERVAL - 4 MONTH)
    QUERY
  end

  def find_user_id_from_email(email)
    get_users.find { |u| u['emailAddress'] == email }.try(:dig, 'userId')
  end

  def get_user_map
    community_users = sf_community_users = sf.client.query(<<-QUERY)
      SELECT Id, FirstName, LastName, Email, SWC_User_ID__c, CCL_Community_Username__c 
      FROM Contact 
      WHERE CCL_Community_Username__c <> '' AND SWC_User_ID__c <> 0
    QUERY

    community_users.inject({}) do |map, user| 
      if user.SWC_User_ID__c.to_i.nonzero?
        # map[user.CCL_Community_Username__c] = user.SWC_User_ID__c.to_i
        map[user.CCL_Community_Username__c] = user
      end
      map
    end
  end
end