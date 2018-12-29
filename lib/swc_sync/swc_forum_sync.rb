# frozen_string_literal: true
require 'active_support/all'
require_relative '../web_sync/json_web_token'
require_relative '../web_sync/mysql_connection'
require_relative '../web_sync/throttled_api_client'
require_relative '../salesforce_sync'

class SwcForumSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'swc.log'))

  attr_accessor :api
  attr_accessor :sf
  attr_accessor :wp

  # map old to new forum categories. WP forum_slug => swc forum category id
  FORUM_CATEGORY_MAP = {
    'the-policy' => 1904,
    'the-politics' => 58,
    'endorsements-1' => 61,
    'media-and-outreach' => 59,
    'general-other-questions' => 33
  }

  def initialize
    @api = ThrottledApiClient.new(api_url: "https://#{ENV['SWC_AUDIENCE']}/services/4.0/",
                                logger: LOG, token_method: JsonWebToken.method(:swc_token))
    @sf = SalesforceSync.new
    @wp = MysqlConnection.get_connection
  end

  # wp_sftopics
  # topic_id, topic_name, topic_date, forum_id, user_id, topic_opened, topic_slug, post_id, post_count
  def get_topics(category)

  end

  def get_wp_category(category) 
    # wp_sfforums
  end

  # post_id, post_content, post_date, topic_id, user_id, forum_id
  def get_wp_posts(category = 'the-policy')
    # wp_sfposts
    wp.query(<<-QUERY)
      SELECT f.forum_id, t.topic_id, topic_slug, topic_name, topic_date, t.user_id topic_user, 
        p.post_id, post_content, post_date post_date, p.user_id 
      FROM wp_sftopics t 
      JOIN wp_sfforums f ON f.forum_id = t.forum_id 
      JOIN wp_sfposts p ON p.post_id = t.post_id
      WHERE f.forum_slug = '#{category}'
      ORDER BY t.topic_date DESC, p.post_date DESC
    QUERY
  end

end