# frozen_string_literal: true
require 'active_support/all'
require_relative '../web_sync/json_web_token'
require_relative '../web_sync/mysql_connection'
require_relative '../web_sync/throttled_api_client'
require_relative '../salesforce_sync'

class SwcForumSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'swc_forum.log'))
  POSTED_BY_MESSAGE = '<p><i>Originally Posted By: %s</i></p>'
  DEFAULT_POST_OWNER = 1

  attr_accessor :api
  attr_accessor :sf
  attr_accessor :wp
  attr_accessor :user_map

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
    @user_map = get_user_map
  end

  def sync_forum_posts(forum_name)
    # category_id
    swc_forum_id = FORUM_CATEGORY_MAP[forum_name]

    get_wp_posts(forum_name).group_by{|post| post['topic_id']}.each do |topic_id, posts|
      # save the topic
      topic_id = save_topic(swc_forum_id, posts.first)

      # save all of the posts for the topic except the first one
      posts[1..-1].each do |post|
        save_post(swc_forum_id, topic_id, post)
      end
    end
  end

  def save_post(category_id, topic_id, row)
    swc_user_id = @user_map[row.dig('post_user_name')]
    swc_user_id = swc_user_id || DEFAULT_POST_OWNER

    body = swc_user_id == DEFAULT_POST_OWNER ? (POSTED_BY_MESSAGE % row['post_user_name']) + row['post_content'] : row['post_content']

    post = { 'categoryId': category_id, 'topicId': topic_id, 'groupId': 0, 'userId': swc_user_id, 'subject': 'Re: ' + row['topic_name'],
              'body': body, 'locked': false, 'type': 'standard', 'created': row['topic_date'] }
    LOG.info('Create Post: ' + post.as_json.to_s)

    res = @api.post(endpoint: 'forums/posts', data: post)
    sleep @api.time_between_calls
  end

  def save_topic(category_id, row)
    swc_user_id = @user_map[row.dig('topic_user_name')]
    swc_user_id = swc_user_id || DEFAULT_POST_OWNER

    body = swc_user_id == DEFAULT_POST_OWNER ? (POSTED_BY_MESSAGE % row['topic_user_name']) + row['post_content'] : row['post_content']

    topic = { 'categoryId': category_id, 'groupId': 0, 'userId': swc_user_id, 'title': row['topic_name'],
              'body': body, 'locked': false, 'type': 'standard', 'created': row['topic_date'] }
    LOG.info('Create Topic: ' + topic.as_json.to_s)

    new_topic = @api.post(endpoint: 'forums/topics', data: topic)
    #  => "{\n    \"topicId\": \"315\",\n    \"categoryId\": \"33\",\n    \"groupId\": \"0\",\n    \"title\": \"API+post\",\n    \"userId\": \"26\",\n    \"time\": \"2018-12-27T14:11:00-08:00\",\n    \"views\": \"0\",\n    \"replies\": \"0\",\n    \"locked\": false,\n    \"type\": \"standard\",\n    \"firstPostId\": \"0\",\n    \"firstPostUserId\": \"0\",\n    \"lastPostId\": \"0\",\n    \"lastPostUserId\": \"0\",\n    \"lastPostSubject\": \"\",\n    \"lastPostTime\": null,\n    \"hidden\": false,\n    \"statusId\": \"0\"\n}" 
    sleep @api.time_between_calls
    JSON.parse(new_topic.body).dig('topicId')
  end

  def get_user_map
    community_users = sf_community_users = sf.client.query(<<-QUERY)
      SELECT Id, FirstName, LastName, Email, SWC_User_ID__c, CCL_Community_Username__c 
      FROM Contact 
      WHERE CCL_Community_Username__c <> '' AND SWC_User_ID__c <> 0
    QUERY

    community_users.inject({}) do |map, user| 
      if user.SWC_User_ID__c.to_i.nonzero?
        map[user.CCL_Community_Username__c] = user.SWC_User_ID__c.to_i
      end
      map
    end
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