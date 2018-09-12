
require 'rest-client'
require 'json'
require 'active_support/all'
require_relative 'web_sync/mysql_connection'
require 'csv'

class WpSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'wp.log'))
  POST_CONTENT = File.join(File.dirname(__FILE__), '..', 'data', 'cf_d_post_content.csv')

  attr_accessor :wp_client

  def initialize
    @wp_client = MysqlConnection.get_connection
  end

  def cf_d_text_query
    wp_client.query(<<-QUERY)
    SELECT id, post_title, post_name, guid link, post_date, post_status, post_content, post_type
    FROM wp_posts
    WHERE post_type = 'page' 
      AND(INSTR(post_content, 'Carbon Fee') OR INSTR(post_content, 'CF&D') OR INSTR(post_content, 'Fee and Dividend') OR INSTR(post_content, 'CF and D') OR INSTR(post_content, 'CF&amp;D') OR INSTR(post_content, 'CF &amp; D'))
    QUERY
  end

  def write_cf_d_text_list
    CSV.open(POST_CONTENT, 'w') do |csv|
      csv << %w(id, post_title, post_name, link, post_date, post_status, post_content, post_type)
      cf_d_text_query.each do |page|
        match = [/CF&D/i, /Fee and Dividend/i, /CF and D/i, /CF&amp;/i, /CF &amp;/i]
        content = page['post_content']
        post_content = match.select{|reg| content =~ reg}.
              map{|reg| content.enum_for(:scan, reg).map {Regexp.last_match.begin(0)}.
                  map{|index| "'...#{content[(index - 45).clamp(0, content.length)..(index + 45).clamp(0, content.length)]}...'"}
              }.flatten.join(' / ')
        csv << [page['id'], page['post_title'], page['post_name'], page['link'], page['post_date'], page['post_status'], post_content, page['post_type']]
      end
    end
  end

end