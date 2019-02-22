# frozen_string_literal: true
require 'active_support/all'
require 'pry'
require 'csv'
require_relative '../web_sync/json_web_token'
require_relative '../web_sync/throttled_api_client'
require_relative '../salesforce_sync'

class SwcContactImportSync
  LOG_FILE = File.join(File.dirname(__FILE__), '..', '..', 'log', 'swc_contact_update.log')
  # LOG = Logger.new(LOG_FILE)
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'group_messaging_toggle_reverse.log'))
  CONTACT_IMPORT_FILE_LOCATION = File.join(File.dirname(__FILE__), '..', '..', 'data', 'contact_import.json')
  CONTACTS_TO_CLEAR_FILE_LOCATION = File.join(File.dirname(__FILE__), '..', '..', 'data', 'contact_import_to_clear.json')
  WAIVER_SEGMENTS = File.join(File.dirname(__FILE__), '..', '..', 'data', 'waiver_segment.csv')
  GROUP_MESSAGING = File.join(File.dirname(__FILE__), '..', '..', 'data', 'group_messaging_toggle.json')
  SYNCED_USERS = File.join(File.dirname(__FILE__), '..', '..', 'data', 'swc_contact_import.1.log')
  NEED_MEMBERSHIP_IDS = File.join(File.dirname(__FILE__), '..', '..', 'data', 'Missing_SWC_ID_on_Sub_Group.csv')
  MEMBERSHIP_IDS = File.join(File.dirname(__FILE__), '..', '..', 'data', 'Missing_SWC_ID_on_Sub_Group.json')
  MATCHES = /^.*: (\d*),.*$/;
  MAX_CALLS_PER_SECOND = 0.4
  GROUP_CHAPTER_CATEGORY = 4
  ACTION_TEAM_CATEGORY = 5

  # Country_Full_Name__c: 331, 
  PROFILE_FIELD_MAP = {Congressional_District_Short_Name__c: 323, 
    Region__c: 324, Group_Name__c: 322, MailingPostalCode: 329, 
    MailingState: 349, MailingCity: 348}

  attr_accessor :api
  attr_accessor :sf
  attr_accessor :user_map
  attr_accessor :sf_contacts

  def initialize
    @api = ThrottledApiClient.new(api_url: "https://#{ENV['SWC_AUDIENCE']}/services/4.0/",
                                logger: LOG, token_method: JsonWebToken.method(:swc_token))
    @sf = SalesforceSync.new
    # @wp = MysqlConnection.get_connection
  end

  def get_users
    @users.present? ? @users : @users = call(endpoint: 'users', params:{activeOnly: :false})
  end

  def update_user_groups_and_profile
    # get users from SF with group info
    sf_users = get_sf_community_users
    # build map of swc_id to swc_group_id
    # sf_groups = sf_users.each_with_object({}){|sf_user, map| map[sf_user.SWC_User_ID__c&.to_i] = sf_user.Group_del__r&.SWC_Group_ID__c&.to_i}

    # swc_users = api.call(endpoint: 'users?activeOnly=false&embed=groups')
    # map of community users to the groups they are already in
    # user_groups = swc_users.each_with_object({}){|user, map| map[user['userId']] = user['groups']}

    # which users are not already in their group
    # need_tied = sf_groups.select{|id, group_id| user_groups.dig(id.to_s).to_a.exclude?(group_id.to_s)}
    # p "#{need_tied.size} users need updated with group info.."
    # LOG.info("#{need_tied.size} users need updated with group info..")

    # already_tied = File.readlines(SYNCED_USERS).map(&:strip).uniq.map(&:to_s)
    log_file = File.readlines(LOG_FILE)
    already_tied = log_file.map{|line| line.match(/^.*: (\d*).*/)&.captures&.first }.compact.uniq

    call_count = 0

    # sf_groups.reverse_each do |swc_id, group_id|
    sf_users.each do |sf_user|
      swc_id = sf_user.SWC_User_ID__c&.to_i
      group_id = sf_user.Group_del__r&.SWC_Group_ID__c&.to_i

      next if already_tied.include?(swc_id.to_i.to_s)
      
      api.post(endpoint: "groups/#{group_id}/members", data: {userId: swc_id, status: 1})
      sleep 0.4
      set_user_profile_fields(sf_user)
      sleep 0.4
      call_count += 1
      if call_count >= 500
        api.reset_token
        call_count = 0
        LOG.info("resetting token")
      end
      message = "#{swc_id}, #{group_id} - tied"
      LOG.info(message)
      p message
    end
  end
  
  def set_group_messaging
    groups = api.call(endpoint: 'groups')

    message_toggle = []

    groups.each do |group|
      message_toggle << { 'o_group_id': group['id'],'*_name': group['name'], '*_description': group['description'], '*_category_id': group['categoryId'],
        '*_owner_user_id': group['ownerId'],  'o_content_messages': '1' }
    end

    File.open(GROUP_MESSAGING, 'w') {|f| f.puts(message_toggle.to_json)}
  end

  def build_user_export(limit = 1000)
    # first get all users with SWC ID and primary group id
    sf_users = get_sf_community_users
    to_import = sf_users.map(&method(:user_import_json))
    # for each user up to the limit build a JSON import file
    # to_import.each_slice(0, limit)
    File.open(CONTACT_IMPORT_FILE_LOCATION, 'w') { |f| f.puts(to_import.slice(0, limit).to_json) }
  end

  def user_import_json(sf_user)
    { '*_email_address': sf_user.Email.to_s.gsub('+', '%2B'), '*_username': sf_user.FirstName + ' ' + sf_user.LastName,
      '*_first_name': sf_user.FirstName, '*_last_name': sf_user.LastName, 'o_groups': sf_user&.Group_del__r&.SWC_Group_ID__c&.to_i}
  end

  def find_user_id_from_email(email)
    get_users.find { |u| u['emailAddress'] == email }.try(:dig, 'userId')
  end

  def set_all_profile_fields
    already_tied = File.readlines(SYNCED_USERS).map(&:strip).uniq.map{|n| n.to_i.to_s}
    sf_users = get_sf_community_users
    sf_users.each do |user| 
      next if already_tied.include?(user.SWC_User_ID__c.to_i.to_s)
      set_user_profile_fields(user); sleep MAX_CALLS_PER_SECOND
    end
  end

  def set_user_profile_fields(sf_user)
    profileFields = PROFILE_FIELD_MAP.select{|attr, _field_id| sf_user.send(attr).present?}
                        .map{|attr, field_id| {id: field_id, data: CGI.escape(sf_user.send(attr))}}
    profileFields << {id: 331, data: 0} if sf_user.Country_Full_Name__c == "United States"
    update = {userId: sf_user.SWC_User_ID__c.to_i, username: sf_user.FirstName + ' ' + sf_user.LastName, 
      emailAddress: sf_user.Email.to_s.gsub('+', '%2B'), firstName: sf_user.FirstName, lastName: sf_user.LastName,
      profileFields: profileFields}
    results = api.put(endpoint: "users/#{sf_user.SWC_User_ID__c.to_i.to_s}", data: update)
    LOG.info("#{sf_user.SWC_User_ID__c.to_i} profile fields updated")
    # binding.pry if sf_user.SWC_User_ID__c.to_i == 0
    results
  end

  def set_group_messaging
    groups = api.call(endpoint: 'groups')
    group_leaders = sf.client.query("SELECT Id, Email, FirstName, LastName, Group_Leader_del__c, SWC_User_ID__c, Group_del__r.SWC_Group_ID__c,
      Group_del__c FROM Contact WHERE Group_Leader_del__c = True AND SWC_User_ID__c <> null AND Group_del__c <> null")
      
    leaders_by_group = group_leaders.each_with_object({}) do |leader, map|
      if leader&.Group_del__c.present? && leader.SWC_User_ID__c.present? && leader.Group_del__r&.SWC_Group_ID__c.present?
        map[leader.Group_del__r.SWC_Group_ID__c.to_i.to_s] ||= []
        map[leader.Group_del__r.SWC_Group_ID__c.to_i.to_s] << leader.SWC_User_ID__c.to_i.to_s
      end
    end

    already_tied = []
    ['group_messaging_toggle.log', 'group_messaging_toggle_reverse.log', 'group_messaging_toggle_middle.log'].each do |file_name|

    end
    groups1 = File.readlines(File.join(File.dirname(__FILE__), '..', '..', 'log', 'group_messaging_toggle.log'))
    groups2 = File.readlines(File.join(File.dirname(__FILE__), '..', '..', 'log', 'group_messaging_toggle_reverse.log'))
    groups3 = File.readlines(File.join(File.dirname(__FILE__), '..', '..', 'log', 'group_messaging_toggle_middle.log'))

    already_tied = lines.map{|line| line.match(/^.*group_id: (\d*).*$/)&.captures&.first }.compact.uniq

    # break into thirds 972 / 3 = 324
    middle = groups.each_slice(324).to_a[1]
    
    call_count = 0
    # for each group get the members
    middle.each do |group|
      # get group membership records... If we RESET settings then no need to embed notifications here
      group_members = api.call(endpoint: "groups/#{group['id']}/members?embed=notifications")
      call_count += 1
      sleep 0.4
      group_members.each do |group_membership|
        # for each group membership toggle messages on TODO: do we set constant or preserve their notifications?
        # TODO: lets say we keep their settings and just flip on messaging
        new_notifications = group_membership['notifications']
        new_notifications['messages'] = true
        data = {'userId': group_membership['userId'], 'notifications': new_notifications}

        if(leaders_by_group.has_key?(group['id']) && leaders_by_group[group['id']].include?(group_membership['userId']))
          data['status'] = 2
          LOG.info("ADMIN: #{data}")
        end
        
        res = api.put(endpoint: "groups/#{group['id']}/members/#{group_membership['id']}", data: data)
        call_count += 1
        sleep 0.4
        LOG.info("NOTIFICATIONS UPDATED: group_id: #{group['id']}, user_id: #{group_membership['userId']}, membership_id: #{group_membership['id']}")
        if call_count >= 100
          api.reset_token
          call_count = 0
          LOG.info("resetting token...") 
        end
      end
    end
  end

  def find_sf_user(email, sf_users)
    sf_users.find do |sf_user|
      sf_user.Email == email || sf_user.Alternate_Email__c == email || sf_user.CCL_Email_Three__c == email || sf_user.CCL_Email_Four__c == email
    end
  end

  def set_liability_waiver
    waiver_tier = "92"
    to_clear = CSV.readlines(WAIVER_SEGMENTS)
    emails = to_clear.map{|w| w[2]}.uniq
    sf_users = new_sf_community_users
    emails.each do |email|
      # sf_user = find_sf_user(email, sf_users)
      sf_user = sf_users[email]
      if(sf_user)
        # find that user with segments
        swc_user = api.call(endpoint: "users/#{sf_user.SWC_User_ID__c.to_i.to_s}?embed=tiers")
        sleep 0.4
        if(swc_user && swc_user['tiers'].present? && swc_user['tiers'].exclude?(waiver_tier))
          # update add waiver tier
          new_tiers = swc_user['tiers'] + [waiver_tier]
          update = {userId: swc_user['userId'], username: swc_user['username'], emailAddress: swc_user['emailAddress'], 
            firstName: swc_user['firstName'], lastName: swc_user['lastName'], tiers: new_tiers}
          results = api.put(endpoint: "users/#{swc_user['userId']}", data: update)
          sleep 0.4
          LOG.info("WAIVER: #{update}")
        end
      end
    end
  end

  def get_sf_conservative_action_team
    @sf_contacts = sf.client.query(<<-QUERY)
      SELECT Id, FirstName, LastName, Email, SWC_User_ID__c, CCL_Community_Username__c, Group_del__c, Group_del__r.SWC_Group_ID__c,
        Congressional_District_Short_Name__c, Region__c, Group_Name__c, MailingPostalCode, Country_Full_Name__c, MailingState, MailingCity 
      FROM Contact 
      WHERE (CCL_Community_Username__c = '' OR CCL_Community_Username__c = null) AND SWC_User_ID__c <> 0 AND Group_del__c <> '' AND SWC_User_ID__c <> null
        AND Group_del__r.SWC_Group_ID__c <> 0 AND Group_del__r.SWC_Group_ID__c <> null
    QUERY
  end

  # NOTE: this does not grab contacts who are not part of a chapter or part of a chapter without a SWC ID
  def get_sf_community_users
    return @sf_contacts if @sf_contacts
    @sf_contacts = sf.client.query(<<-QUERY)
      SELECT Id, FirstName, LastName, Email, SWC_User_ID__c, CCL_Community_Username__c, Group_del__c, Group_del__r.SWC_Group_ID__c,
        Congressional_District_Short_Name__c, Region__c, Group_Name__c, MailingPostalCode, Country_Full_Name__c, MailingState, MailingCity 
      FROM Contact 
      WHERE SWC_User_ID__c <> 0 AND Group_del__c <> '' AND SWC_User_ID__c <> null AND Group_del__r.SWC_Group_ID__c <> 0 AND Group_del__r.SWC_Group_ID__c <> null
    QUERY
    @sf_contacts
  end

  def new_sf_community_users
    contacts = community_users = sf.client.query(<<-QUERY)
      SELECT Id, FirstName, LastName, Email, Alternate_Email__c, CCL_Email_Three__c, CCL_Email_Four__c, SWC_User_ID__c
      FROM Contact 
      WHERE SWC_User_ID__c <> 0 AND SWC_User_ID__c <> null
    QUERY

    @sf_contacts = contacts.inject({}) do |map, user| 
      if user.SWC_User_ID__c.to_i.nonzero?
        map[user.Email] = user
      end
      map
    end
  end
end