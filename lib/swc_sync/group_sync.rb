# frozen_string_literal: true

require 'active_support/all'
require 'pry'
require 'csv'
require_relative '../web_sync/json_web_token'
require_relative '../web_sync/throttled_api_client'
require_relative '../salesforce_sync'

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
    groups_with_zip = swc_chapters.select { |g| g.dig('address').dig('zip').present? && postal_codes.key?(g.dig('address').dig('zip').to_s.strip) }

    groups_with_zip.each do |group|
      sf_group = sf_groups[group['id']]
      swc_zip = group['address']['zip'].to_s.strip
      zip = postal_codes[swc_zip]

      next unless zip.present? && (sf_group&.Postal_Code_Data__r&.Name.to_s != swc_zip)

      LOG.info("Group #{sf_group&.Name} (#{sf_group&.Id}) zip #{sf_group&.Postal_Code_Data__r&.Name} <> #{swc_zip} for #{group['name']} - #{group['id']}. Zip to set: #{zip.Id}")
      sf_group.Postal_Code_Data__c = zip.Id
      sf_group.save
    end
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
end
