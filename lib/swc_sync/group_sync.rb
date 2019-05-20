# frozen_string_literal: true

require 'active_support/all'
require 'pry'
require 'csv'
require_relative '../web_sync/json_web_token'
require_relative '../web_sync/throttled_api_client'
require_relative '../salesforce_sync'
require_relative '../web_sync/email_notifier'

class GroupSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'swc_group_sync.log'))

  attr_accessor :api
  attr_accessor :sf
  attr_accessor :user_map
  attr_accessor :sf_contacts

  def initialize
    @api = ThrottledApiClient.new(api_url: "https://#{ENV['SWC_AUDIENCE']}/services/4.0/",
                                  logger: LOG, token_method: JsonWebToken.method(:swc_token))
    @sf = SalesforceSync.new
  end

  def update_address
    postal_codes = get_sf_postal_codes.index_by(&:Name)
    sf_groups = get_sf_chapters.index_by { |group| group.SWC_Group_ID__c.to_i.to_s }
    swc_chapters = get_swc_chapters

    # should I write the zip back to SWC if SWC is blank?
    groups_with_zip = swc_chapters.select do |g|
      # only for US postal codes
      g.dig('address').present? && g.dig('address').dig('zip').present? && g.dig('address').dig('country') == 'USA'
    end

    missing_postal_codes = []

    groups_with_zip.each do |group|
      sf_group = sf_groups[group['id']]
      swc_zip = group['address']['zip'].to_s.strip
      zip = postal_codes[swc_zip]

      if zip.blank? || sf_group.nil?
        message = "No SF #{zip.blank? ? 'postal code' : 'SF group'} for #{swc_zip}, Group #{group['name']}, ID: #{group['id']}"
        LOG.info(message)
        missing_postal_codes << message
        next
      end

      next unless zip.present? && (sf_group&.Postal_Code_Data__r&.Name.to_s != swc_zip)

      LOG.info("Group #{sf_group&.Name} (#{sf_group&.Id}) zip #{sf_group&.Postal_Code_Data__r&.Name} <> #{swc_zip} for #{group['name']} - #{group['id']}. Zip to set: #{zip.Id}")
      sf_group.Postal_Code_Data__c = zip.Id
      sf_group.save
    end

    send_missing_zips(missing_postal_codes) if missing_postal_codes.any?
  end

  def get_swc_chapters
    api.call(endpoint: 'groups?categoryId=4')
  end

  def get_sf_chapters
    @sf_contacts = sf.client.query(<<-QUERY)
      SELECT Id, Name, SWC_Group_ID__c, Postal_Code_Data__c, Postal_Code_Data__r.Name
      FROM Group__c
      WHERE SWC_Group_ID__c <> 0 AND SWC_Group_ID__c <> null AND Country__c = 'USA'
    QUERY
  end

  def get_sf_postal_codes
    @sf_contacts = sf.client.query(<<-QUERY)
      SELECT Id, Name, City__c, State_Province__r.Abbreviation__c
      FROM Postal_Code__c
    QUERY
  end

  def send_missing_zips(messages)
    to = 'bryan.hermsen@citizensclimate.org'
    EmailNotifier.new.send_email(subject: 'Missing Postal Codes', body: "Missing postal Codes: \n#{messages.join('\n')}", to: to)
  end

  # JSON import file 930 / 932 for staging test
  def get_group_import
    group_import_file_location = File.join(File.dirname(__FILE__), '..', '..', 'data', 'group_import.csv')
    groups = [api.call(endpoint: 'groups/931?embed=permissions,notifications,address,news,welcomeMessage,inviteMessage')]
    # groups = api.call(endpoint: 'groups?embed=permissions,notifications,address,news,welcomeMessage,inviteMessage')

    upload = groups.map(&method(:csv_for_swc))
    upload.unshift(['o_group_id', '*_name', '*_description', '*_category_id', '*_owner_user_id', 'o_access_level', 'o_address', 'o_invite_message', 'o_welcome_message',
                    'o_news', 'o_content_forums', 'o_content_events', 'o_content_photos', 'o_content_videos', 'o_content_files', 'o_content_members',
                    'o_content_messages', 'o_photo_location'])
    # File.open(group_import_file_location, 'w') { |f| f.puts(upload.to_json) }
    CSV.open(group_import_file_location, 'w') { |csv| upload.each { |row| csv << row } }
  end

  def json_for_swc(g)
    { 'o_group_id': g['id'], '*_name': CGI.unescape(g['name'].to_s), '*_description': CGI.unescape(g['description'].to_s),
      '*_category_id': g['categoryId'], '*_owner_user_id': g['ownerId'].to_s, 'o_access_level': g['status'],
      'o_address': json_group_address(g), 'o_invite_message': g['inviteMessage'].present? ? CGI.unescape(g['inviteMessage'].to_s) : nil,
      'o_welcome_message': g.dig('welcomeMessage', 'message').present? ? CGI.unescape(g.dig('welcomeMessage', 'message')) : nil,
      'o_news': g['news'].present? ? CGI.unescape(g['news'].to_s) : nil,
      'o_content_forums': '2', 'o_content_events': '1', 'o_content_photos': '1',
      'o_content_videos': '1', 'o_content_files': '1', 'o_content_members': '1', 'o_content_messages': '2',
      'o_photo_location': g.dig('photo', 'fileLocation') }
  end

  def csv_for_swc(g)
    [g['id'], CGI.unescape(g['name'].to_s), CGI.unescape(g['description'].to_s), g['categoryId'], g['ownerId'].to_s, g['status'],
     json_group_address(g), g['inviteMessage'].present? ? CGI.unescape(g['inviteMessage'].to_s) : nil,
     g.dig('welcomeMessage', 'message').present? ? CGI.unescape(g.dig('welcomeMessage', 'message')) : nil,
     g['news'].present? ? CGI.unescape(g['news'].to_s) : nil,
     '2', '1', '1', '1', '1', '1', '2', g.dig('photo', 'fileLocation')]
  end

  def json_group_address(g)
    return nil unless g&.dig('address')

    address = g.dig('address')
    [address.dig('line1'), address.dig('line2'), address.dig('city'), address.dig('state'), address.dig('zip'), address.dig('country')].map(&:to_s).join(',')
  end
end
