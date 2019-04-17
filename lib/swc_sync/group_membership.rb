# frozen_string_literal: true

require 'active_support/all'
require 'pry'
require 'csv'
require_relative '../web_sync/json_web_token'
require_relative '../web_sync/throttled_api_client'
require_relative '../salesforce_sync'

class GroupMembership
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'disable_notifications.log'))
  MISSING_ID = File.join(File.dirname(__FILE__), '..', '..', 'data', 'Missing SWC_ID.csv')
  WITH_IDS = File.join(File.dirname(__FILE__), '..', '..', 'data', 'with_ids.csv')

  attr_accessor :api
  attr_accessor :sf
  attr_accessor :user_map
  attr_accessor :sf_contacts

  def initialize
    @api = ThrottledApiClient.new(api_url: "https://#{ENV['SWC_AUDIENCE']}/services/4.0/",
                                  logger: LOG, token_method: JsonWebToken.method(:swc_token))
    @sf = SalesforceSync.new
  end

  def disable_new_member_notifications(group_id: 2131)
    members = api.call(endpoint: "groups/#{group_id}/members?embed=notifications") # .select{|m| m['notifications']['members']}

    call_count = 0
    members.each do |group_membership|
      new_notifications = group_membership['notifications']
      new_notifications['members'] = group_membership['status'] != '1'
      new_notifications['photos'] = false
      new_notifications['videos'] = false
      new_notifications['files'] = false
      new_notifications['messages'] = true # make sure this should really be true
      data = { userId: group_membership['userId'], status: group_membership['status'], notifications: new_notifications }

      res = api.put(endpoint: "groups/#{group_id}/members/#{group_membership['id']}", data: data)
      call_count += 1
      LOG.info("NOTIFICATIONS UPDATED: group_id: #{group_id}, user_id: #{group_membership['userId']}, membership_id: #{group_membership['id']}")
      next unless call_count >= 100

      api.reset_token
      call_count = 0
      LOG.info('resetting token...')
    end
  end

  def add_members_from_group_to_group(from_group: 934, to_group: 944)
    from_members = api.call(endpoint: "groups/#{from_group}/members").map { |sm| sm['userId'] }
    current_members = api.call(endpoint: "groups/#{to_group}/members").map { |sm| sm['userId'] }
    members_should_be_in_group = from_members.select { |user_id| current_members.exclude?(user_id) }

    members_should_be_in_group.each do |member_id|
      response = api.post(endpoint: "groups/#{to_group}/members", data: { userId: member_id })
      binding.pry
      LOG.info("user: #{member_id} from #{from_group} to_group_id: #{to_group}, res: #{response.to_s.delete("\n").strip}")
    end
  end

  def add_group_zip_code
    # get all chapters with a zip code and SWC ID
    sf_groups = get_sf_groups
    by_id = sf_groups.group_by { |g| g.SWC_Group_ID__c.to_i.to_s }

    # get all chapters from SWC
    swc_groups = api.call(endpoint: 'groups?categoryId=4')

    # if there's no zip find in SF list and set zip, retaining city/state
    swc_groups.each do |swc_group|
      address = swc_group.dig('address')
      next unless address&.dig('zip')&.empty? && by_id.key?(swc_group['id'])

      sf_group = by_id[swc_group['id']].first
      address['zip'] = sf_group.Postal_Code_Data__r.Name
      address.delete('latitude')
      address.delete('longitude')
      data = { ownerId: swc_group['ownerId'], categoryId: swc_group['categoryId'], name: swc_group['name'],
               description: swc_group['description'], address: address }
      res = api.put(endpoint: "groups/#{swc_group['id']}", data: data)
      LOG.info("group: #{swc_group['id']} set zip, data: #{data}, res: #{res.to_s.delete("\n").strip}")
    end
  end

  # TODO: DISABLE welcome emails
  # toggle group membership notifications for owner.
  def set_conservative_caucus_members
    caucus_members = get_conservative_caucus_members
    conservative_caucus_group_id = 965

    caucus_members.each do |sf_user|
      user_id = sf_user.SWC_User_ID__c.to_i.to_s
      response = api.post(endpoint: "groups/#{conservative_caucus_group_id}/members", data: { userId: user_id })
      LOG.info("sf_it: #{user_id}, group_id: #{conservative_caucus_group_id}, res: #{response.to_s.delete("\n").strip}")
    end
  end

  def get_conservative_caucus_members
    sf.client.query(<<-QUERY)
      SELECT Id, FirstName, LastName, Email, Alternate_Email__c, CCL_Email_Three__c, CCL_Email_Four__c, SWC_User_ID__c, CCL_Community_Username__c,
        Conservative_Caucus_Membership__c
      FROM Contact
      WHERE SWC_User_ID__c <> 0 AND SWC_User_ID__c <> null AND Conservative_Caucus_Membership__c <> ''
    QUERY
  end

  def get_group_membership_by_user_and_group
    missing_ids = CSV.readlines(MISSING_ID)[1..-1]

    missing_ids.each do |line|
      sf_ids = line[0].to_s
      swc_user_id = line[3].to_i.to_s
      swc_group_id = line[4].to_i.to_s

      response = api.post(endpoint: "groups/#{swc_group_id}/members", data: { userId: swc_user_id, status: 1 })
      LOG.info("sf_id: #{sf_ids}, group: #{swc_group_id}, swc_user_id: #{swc_user_id}, response: #{response}")
    end
  end

  def set_chapter_members(group_id:)
    logger = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'set_swc_chapter_members.log'))
    chapter_members = get_sf_chapter_members(group_id: group_id)

    chapter_members.each do |sf_user|
      user_id = sf_user.SWC_User_ID__c.to_i.to_s
      response = api.post(endpoint: "groups/#{group_id}/members", data: { userId: user_id })
      logger.info("sf_id: #{user_id}, group_id: #{group_id}, res: #{response.to_s.delete("\n").strip}")
    end
  end

  def remove_members_not_in_chapter(group_id:)
    # sf_members = get_sf_chapter_members(group_id: group_id).map{|sm| sm.SWC_User_ID__c.to_i.to_s}
    sf_members = get_liaisons.map { |sm| sm.SWC_User_ID__c.to_i.to_s }
    swc_members = api.call(endpoint: "groups/#{group_id}/members")

    members_not_in_chapter = swc_members.select { |sm| sf_members.exclude?(sm['userId']) }

    members_not_in_chapter.each do |member|
      did_delete = api.send_delete(endpoint: "groups/#{group_id}/members/#{member['id']}")
      if did_delete == true
        LOG.info("DELETE - swc_id: #{member['userId']}, group_id: #{group_id}, member_id: #{member['id']}")
      else
        LOG.info("DELETE FAILED - swc_id: #{member['userId']}, group_id: #{group_id}, member_id: #{member['id']}")
      end
    end
  end

  def add_members_not_in_chapter(group_id:)
    logger = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'set_swc_chapter_members.log'))
    sf_members = get_sf_chapter_members(group_id: group_id).map { |sm| sm.SWC_User_ID__c.to_i.to_s }
    swc_members = api.call(endpoint: "groups/#{group_id}/members").map { |sm| sm['userId'] }

    members_should_be_in_chapter = sf_members.select { |user_id| swc_members.exclude?(user_id) }

    members_should_be_in_chapter.each do |member_id|
      res = api.post(endpoint: "groups/#{group_id}/members", data: { userId: member_id })
      logger.info("sf_id: #{member_id}, group_id: #{group_id}, res: #{res.to_s.delete("\n").strip}")
    end
  end

  def print_group_members(group_id:)
    members = api.call(endpoint: "groups/#{group_id}/members?embed=user")
    to_print = members.map { |m| user = m['user']; [user['userId'], user['username'], user['emailAddress']] }
    CSV.open(File.join(File.dirname(__FILE__), '..', '..', 'data', "group_#{group_id}_members.csv"), 'w') do |csv|
      to_print.each { |line| csv << line }
    end
  end

  def get_sf_chapter_members(group_id:)
    @sf_contacts = sf.client.query(<<-QUERY)
      SELECT Id, SWC_User_ID__c, Group_del__c, Group_del__r.SWC_Group_ID__c
      FROM Contact
      WHERE SWC_User_ID__c <> 0 AND SWC_User_ID__c <> null AND SWC_Allow_Sync__c = true AND
        Group_del__c <> null AND Group_del__r.SWC_Group_ID__c = #{group_id}
    QUERY
  end

  def get_liaisons
    @sf_contacts = sf.client.query(<<-QUERY)
    SELECT Id, SWC_User_ID__c
    FROM Contact
    WHERE SWC_User_ID__c <> 0 AND SWC_User_ID__c <> null AND SWC_Liaison__c <> '' AND SWC_Liaison__c <> null
      AND SWC_Allow_Sync__c = true
    QUERY
  end

  def get_sf_groups
    @sf_contacts = sf.client.query(<<-QUERY)
      SELECT Id, Name, SWC_Group_ID__c, Postal_Code_Data__c, Postal_Code_Data__r.Name
      FROM Group__c
      WHERE SWC_Group_ID__c <> 0 AND SWC_Group_ID__c <> null AND Postal_Code_Data__c <> null
    QUERY
  end

  def set_group_members_from_query
    group_id = 2029
    sf_members = sf.client.query(<<-QUERY)
      SELECT Id, Country_Full_Name__c, Group_Leader_del__c, SWC_User_ID__c FROM Contact
      WHERE Group_Leader_del__c = true AND Country_Full_Name__c = 'Australia' AND SWC_User_ID__c <> null
    QUERY

    sf_members.each do |sf_members|
      res = api.post(endpoint: "groups/#{group_id}/members", data: { userId: sf_members.SWC_User_ID__c.to_i.to_s })
      sleep 0.4
      LOG.info("ADD MEMBER: group_id: #{group_id}, user_id: #{sf_members.SWC_User_ID__c.to_i} res: #{res.to_s.delete("\n").strip}")
    end
  end

  def set_group_admins
    groups = api.call(endpoint: 'groups')
    group_leaders = sf.client.query("SELECT Id, Email, FirstName, LastName, Group_Leader_del__c, SWC_User_ID__c, Group_del__r.SWC_Group_ID__c,
      Group_del__c FROM Contact WHERE Group_Leader_del__c = True AND SWC_User_ID__c <> null AND Group_del__c <> null")

    leaders_by_group = group_leaders.each_with_object({}) do |leader, map|
      if leader&.Group_del__c.present? && leader.SWC_User_ID__c.present? && leader.Group_del__r&.SWC_Group_ID__c.present?
        map[leader.Group_del__r.SWC_Group_ID__c.to_s.to_i] ||= []
        map[leader.Group_del__r.SWC_Group_ID__c.to_s.to_i] << leader.SWC_User_ID__c.to_s.to_i
      end
    end

    groups.each do |group|
      if leaders_by_group.key?(group['id'].to_s.to_i)
        leaders_by_group[group['id'].to_s.to_i].each do |sw_id|
          res = api.put(endpoint: "groups/#{group['id']}/members/#{sw_id}", data: { userId: sw_id.to_s, status: 2 })
          LOG.info("LEADER SET NEW: group_id: #{group['id']}, owner: #{sw_id}, result: #{res}")
          sleep 0.4
        end
      else
        LOG.info("No group leader found for #{group}")
      end
    end
  end

  def write_ids_to_csv
    lines = File.readlines(File.join(File.dirname(__FILE__), '..', '..', 'log', 'set_missing_sub_group_ids.log'))
    record_start = /sf_id: (.*), group:/
    id_line = /^\s*"id": "(\d*)"/

    csv = []
    record = []
    lines.each do |line|
      if line&.match?(record_start)
        record << line.match(record_start).captures.first
      elsif line&.match?(id_line)
        record << line.match(id_line).captures.first
        csv << record
        record = []
      end
    end

    CSV.open(WITH_IDS, 'w') do |file|
      csv.each { |line| file << line }
    end
  end
end
