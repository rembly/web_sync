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
    LOG.info('**** Syncing Addresses between SWC and Salesforce ****')
    postal_codes = get_sf_postal_codes.index_by(&:Name)
    sf_groups = get_sf_chapters.index_by { |group| group.SWC_Group_ID__c.to_i.to_s }
    swc_chapters = get_swc_chapters

    missing_postal_codes = []
    
    swc_chapters.each do |group|
      sf_group = sf_groups[group['id']]
      swc_address = group.dig('address') || {}
      swc_zip = swc_address.dig('zip').to_s.strip
      zip = postal_codes[swc_zip]

      not_usa = swc_address.dig('country').present? && swc_address.dig('country') != 'USA'
      next if not_usa

      if sf_group.nil?
        message = "No SF group for SWC Group #{group['name']}, ID: #{group['id']}"
        LOG.info(message)
        missing_postal_codes << message
        next
      end

      update_salesforce_address_from_swc(group, sf_group, zip, missing_postal_codes)
      update_swc_address_from_sf(group, sf_group)
    end
    
    send_missing_zips(missing_postal_codes) if missing_postal_codes.any?
  end

  def update_swc_address_from_sf(swc_group, sf_group)
    swc_address = swc_group.dig('address') || {}
    swc_zip = swc_address.dig('zip').to_s.strip
    sf_po = sf_group.Postal_Code_Data__r&.Name

    do_save = false

    {'city': 'City__c', 'state': 'State__c', 'country': 'Country__c'}.each do |(sw_field, sf_field)|
      if swc_address.dig(sw_field.to_s).blank? && sf_group.send(sf_field).present?
        swc_address[sw_field] = sf_group.send(sf_field)
        do_save = true
      end
    end

    if swc_zip.blank? && sf_po.present?
      swc_address['zip'] = sf_po
      do_save = true
    end
    
    if do_save
      update = {id: swc_group['id'], name: swc_group['name'], description: swc_group['description'], categoryId: swc_group['categoryId'],
                address: swc_address}
      response = api.put(endpoint: "groups/#{swc_group['id']}", data: update)
      LOG.info("Updating SWC Group #{swc_group['id']}: response: #{response.to_s.delete("\n").strip}")
      # LOG.info("Updating SWC Group #{swc_group['id']}. data: #{update}")
    end

  end
  
  # update the Salesforce postal code if it's been updated in SWC
  def update_salesforce_address_from_swc(swc_group, sf_group, zip, missing_postal_codes)
    swc_address = swc_group.dig('address') || {}
    swc_zip = swc_address.dig('zip').to_s.strip

    if zip.blank?
      message = "No SF postal code for #{swc_zip}, Group #{swc_group['name']}, ID: #{swc_group['id']}"
      LOG.info(message)
      missing_postal_codes << message
      return
    end

    return unless zip.present? && (sf_group&.Postal_Code_Data__r&.Name.to_s != swc_zip)

    LOG.info("Group #{sf_group&.Name} (#{sf_group&.Id}) zip #{sf_group&.Postal_Code_Data__r&.Name} <> #{swc_zip} for #{swc_group['name']} - #{swc_group['id']}. Zip to set: #{zip.Id}")
    sf_group.Postal_Code_Data__c = zip.Id
    sf_group.save
  end

  def get_swc_chapters
    api.call(endpoint: 'groups?categoryId=4')
  end

  def get_sf_chapters
    @sf_contacts = sf.client.query(<<-QUERY)
      SELECT Id, Name, SWC_Group_ID__c, Postal_Code_Data__c, Postal_Code_Data__r.Name, City__c, State__c, Country__c
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
