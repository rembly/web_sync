# frozen_string_literal: true
require 'active_support/all'
require_relative '../web_sync/json_web_token'
require_relative '../web_sync/mysql_connection'
require_relative '../web_sync/throttled_api_client'
require_relative '../salesforce_sync'

class SwcForumSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'swc.log'))
  DEFAULT_POST_OWNER = 1

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

  def sync_forum_posts(forum_name)
    @user_map = get_user_map
    swc_forum_id = FORUM_CATEGORY_MAP[forum_name]

    get_wp_posts(forum_name).group_by{|post| post['topic_id']}.each do |topic_id, posts|
      # save the topic
      topic = save_topic(posts.first)

      # save all of the posts for the topic except the first one
      posts[1..-1].each do |post|
        save_post
      end
    end
  end

  # wp_sftopics
  # topic_id, topic_name, topic_date, forum_id, user_id, topic_opened, topic_slug, post_id, post_count
  def get_topics(category)

  end

  def get_wp_category(category) 
    # wp_sfforums
  end

  def save_topic(category_id, row)
    swc_user_id = row.dig('topic_user')
    swc_user_id = swc_user_id || DEFAULT_POST_OWNER

    topic = { 'categoryId': category_id, 'groupId': 0, 'userId': swc_user_id, 'title': row['topic_name'],
              'body': row['post_content'], 'locked': false, 'type': 'standard', 'created': row['topic_date'] }
    LOG.info('Create Topic: ' + topic)

    # res = @api.post(endpoint: 'forums/topics', data: topic)
  end

  def get_user(row)

  end

  def get_user_map
    community_users = sf_community_users = sf.client.query(<<-QUERY)
      SELECT Id, FirstName, LastName, Email, SWC_User_ID__c, CCL_Community_Username__c 
      FROM Contact 
      WHERE CCL_Community_Username__c <> '' AND SWC_User_ID__c <> 0
    QUERY

    community_users.inject({}){|map, user| map[user.CCL_Community_Username__c] = user.SWC_User_ID__c.to_i; map}
  end

  # post_id, post_content, post_date, topic_id, user_id, forum_id
  def get_wp_posts(category = 'the-policy')
    # wp_sfposts
    wp.query(<<-QUERY).to_a
      SELECT f.forum_id, t.topic_id, topic_slug, topic_name, topic_date, t.user_id topic_user_id, 
        tu.display_name topic_user_name, tu.user_login topic_user, u.user_login post_user, 
        u.display_name post_user_name, p.post_id, post_content, post_date post_date, p.user_id 
      FROM wp_sfposts p 
        JOIN wp_sftopics t ON p.topic_id = t.topic_id
        JOIN wp_sfforums f ON f.forum_id = t.forum_id 
        JOIN wp_users u ON u.id = p.user_id
        JOIN wp_users tu ON tu.id = t.user_id
      WHERE f.forum_slug = '#{category}' AND topic_date >= DATE_SUB(NOW(),INTERVAL 1 YEAR)
      ORDER BY t.topic_date DESC, p.post_date ASC
    QUERY
  end

end