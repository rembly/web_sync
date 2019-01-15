# frozen_string_literal: true
require 'active_support/all'
require 'pry'
require_relative '../web_sync/json_web_token'
require_relative '../web_sync/mysql_connection'
require_relative '../web_sync/throttled_api_client'
require_relative '../salesforce_sync'

class BpActivitySync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'swc_group_forum.log'))
  # map old forum topics and posts to new. Keep a log of conversion
  FORUM_MAP = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'swc_group_forum_map.log'))
  POSTED_BY_MESSAGE = "<p class='forum_disclaimer'><i>Originally posted in old Community by: %s. Links and images may not work correctly.</i></p>"
  TOPIC_TITLE = "Old Community Wall Posts"
  TOPIC_BODY = "<h3>These posts have been migrated over from old community</h3><p><i>Please note that links and images may not work correctly</i></p>"
  POST_DISCLAIMER = "<p class='forum_disclaimer'><i>Originally posted on old Community. Links may no longer be active.</i></p>"
  DEFAULT_POST_OWNER = 1
  MAX_SUBJECT_LENGTH = 75

  # map group slug on WP to [group_id, forum_category]
  FORUM_CATEGORY_MAP = {
    'group-leaders' => [1767,1798],
    'regional-coordinators' => [946,977],
    # 'ny-nj-pa-coordinating': 1,
    'liaisons-1475069368' => [998,1029],
    'ccl-visuals-graphics-art-and-more' => [960,991],
    'clr-caucus' => [965,996], # sub group???? consevative media
    'presenters-schedulers' => [973,1004],
    'team-oil' => [978,1009],
    # 'ccl-book-club': 1, # 'cclsierra-club': 1,
    'agriculture-team' => [968,999],
    'rural-electric-cooperatives' => [974,1005],
    'rotary-service-clubs' => [948,979],
    # 'solo-cclers': 1,
    'climate-change-national-security' => [962,993],
    'climate-peer-support' => [972,1003],
    'coal-country-climate-heroes-578105675' => [964,995],
    'envoys' => [1818,1873],
    'state-carbon-taxes' => [976,1007],
    'unitarian-universalists' => [979,1010],
    'social-media' => [975,1006],
    # 'dc-lodging-for-ccl-lobbyists': 1, # 'team-nuclear': 1,
    'climate-and-healthcare-team' => [961,992],
    'spanish-language' => [995,1026],
    'catholics' => [958,989],
    'ski-and-outdoor-industry' => [984,1015],
    'bahai' => [956,987],
    'team-ocean' => [977,1008],
    'group-development-coaches' => [1769,1806],
    'trainers' => [1770,1807],
    'motivational-interviewing-738232779' => [970,1001],
    # 'millennial-generation': 1, # 'nocal-moc-liaisons': 1, # 'pathway-to-paris': 1, # 'proactive-outreach': 1,
    '100-faith-leaders' => [967,998],
    'endorsement-project' => [1771,1808],
    'labor-outreach' => [969,1000],
    'engaging-youth' => [988/1019],
    # 'healthy-climate-team': 1,
    'environmental-justice' => [953,984], # group rename
    'lds-mormon' => [954,985],
    'presbyterians' => [997,1028],
    'business-climate-leaders' => [986,1017],
    'action-team-leaders' => [1878,1940],
    'higher-education' => [949,980],
    'jewish-action-team' => [955,986],
    'biking-for-climate-action' => [993,1024], # group rename
    'print-media' => [992,1023],
    'progressive-outreach' => [994,1025],
    'quakers' => [991,1022],
    'broadcast-media' => [963,994],
    'climate-reality-leadership-corp' => [989,1020],
    'evangelical-christian-action-team' => [983,1014], # group rename
    'strategic-planning' => [985,1016],
    'episcopal-action-team' => [981,1012], # group rename
    'chinese-action-team' => [980,1011], #group rename
    'lgbtqa-climate' => [1880,1942],
  }

  attr_accessor :api
  attr_accessor :sf
  attr_accessor :wp
  attr_accessor :user_map

  def initialize
    @api = ThrottledApiClient.new(api_url: "https://#{ENV['SWC_AUDIENCE']}/services/4.0/",
                                logger: LOG, token_method: JsonWebToken.method(:swc_token))
    @sf = SalesforceSync.new
    @wp = MysqlConnection.get_connection
    @user_map = get_user_map
  end

  def sync_walls
    to_sync = ['climate-change-national-security']
    to_sync.each(&method(:sync_wall_posts))
  end

  def sync_wall_posts(group_wp_slug)
    group_id, forum_category_id = FORUM_CATEGORY_MAP[group_wp_slug]
    posts = get_wp_activity_posts(group_wp_slug)
    comments = get_wp_activity_post_comments(group_wp_slug).group_by{|post| post['parent_id']}
    topic_id = create_wall_topic(forum_category_id, group_id, posts.first)

    # TODO maybe make a new topic for old group posts? Maybe grab group members and test that before making a post
    # and make as admin if not. Doesn't look like you can post without either being an admin or member of the group.

    posts.each do |post|
      # save all of the posts for the topic except the first one
      # save_post(forum_category_id, topic_id, group_id, post)
      topic_id = save_topic(forum_category_id, group_id, post)

      # if there are comments save those
      comments[post['post_id']].to_a.each do |comment|
        save_post(forum_category_id, topic_id, group_id, comment, post)
      end
    end
  end

  def save_post(category_id, topic_id, group_id, row, parent)
    swc_user_id = @user_map[row.dig('post_user')]
    swc_user_id = swc_user_id || DEFAULT_POST_OWNER

    disclaimer = ''
    if swc_user_id == DEFAULT_POST_OWNER
      disclaimer = POSTED_BY_MESSAGE % row['post_user']
    elsif row.dig('content').to_s.include?('href')
      disclaimer = POST_DISCLAIMER
    end
    
    body = disclaimer + row['content']
    subject = 'Re: ' + parent['content'].size >= MAX_SUBJECT_LENGTH ? parent['content'][0..MAX_SUBJECT_LENGTH] + '...' : parent['content']

    post = { 'categoryId': category_id, 'topicId': topic_id, 'groupId': group_id, 'userId': swc_user_id, 'subject': subject,
              'body': body, 'locked': false, 'type': 'standard', 'created': row['date_recorded'].iso8601 }
    LOG.info('Create Post: ' + post.as_json.to_s)

    new_post = @api.post(endpoint: 'forums/posts', data: post)

    FORUM_MAP.info("POST,#{row['post_id']},#{JSON.parse(new_post.body).dig('postId')}")
    sleep @api.time_between_calls
  end

  def save_topic(category_id, group_id, row)
    swc_user_id = @user_map[row.dig('post_user')]
    swc_user_id = swc_user_id || DEFAULT_POST_OWNER

    disclaimer = ''
    if swc_user_id == DEFAULT_POST_OWNER
      disclaimer = POSTED_BY_MESSAGE % row['post_user']
    elsif row.dig('content').to_s.include?('href')
      disclaimer = POST_DISCLAIMER
    end

    body = disclaimer + row['content']
    title = row['content'].size >= MAX_SUBJECT_LENGTH ? row['content'][0..MAX_SUBJECT_LENGTH] + '...' : row['content']
    topic = { 'categoryId': category_id, 'groupId': group_id, 'userId': swc_user_id, 'title': title,
              'body': TOPIC_BODY, 'locked': false, 'type': 'standard', 'created': row['date_recorded'].iso8601 }
    LOG.info('Create Topic: ' + topic.as_json.to_s)

    new_topic = @api.post(endpoint: 'forums/topics', data: topic)
    #  => "{\n    \"topicId\": \"315\",\n    \"categoryId\": \"33\",\n    \"groupId\": \"0\",\n    \"title\": \"API+post\",\n    \"userId\": \"26\",\n    \"time\": \"2018-12-27T14:11:00-08:00\",\n    \"views\": \"0\",\n    \"replies\": \"0\",\n    \"locked\": false,\n    \"type\": \"standard\",\n    \"firstPostId\": \"0\",\n    \"firstPostUserId\": \"0\",\n    \"lastPostId\": \"0\",\n    \"lastPostUserId\": \"0\",\n    \"lastPostSubject\": \"\",\n    \"lastPostTime\": null,\n    \"hidden\": false,\n    \"statusId\": \"0\"\n}" 
    sleep @api.time_between_calls
    if new_topic.class == Hash
      binding.pry
      p new_topic
    end
    new_id = JSON.parse(new_topic.body).dig('topicId')
    FORUM_MAP.info("TOPIC,#{row['post_id']},#{new_id}")
    return new_id
  end

  # This is only if we do one topic for all wall posts
  def create_wall_topic(category_id, group_id, row)
    swc_user_id = @user_map[row.dig('group_creator')]
    swc_user_id = swc_user_id || DEFAULT_POST_OWNER
    # swc_user_id = DEFAULT_POST_OWNER

    topic = { 'categoryId': category_id, 'groupId': group_id, 'userId': DEFAULT_POST_OWNER, 'title': TOPIC_TITLE,
              'body': TOPIC_BODY, 'locked': false, 'type': 'standard', 'created': row['date_recorded'].iso8601 }
    LOG.info('Create Topic: ' + topic.as_json.to_s)

    new_topic = @api.post(endpoint: 'forums/topics', data: topic)
    #  => "{\n    \"topicId\": \"315\",\n    \"categoryId\": \"33\",\n    \"groupId\": \"0\",\n    \"title\": \"API+post\",\n    \"userId\": \"26\",\n    \"time\": \"2018-12-27T14:11:00-08:00\",\n    \"views\": \"0\",\n    \"replies\": \"0\",\n    \"locked\": false,\n    \"type\": \"standard\",\n    \"firstPostId\": \"0\",\n    \"firstPostUserId\": \"0\",\n    \"lastPostId\": \"0\",\n    \"lastPostUserId\": \"0\",\n    \"lastPostSubject\": \"\",\n    \"lastPostTime\": null,\n    \"hidden\": false,\n    \"statusId\": \"0\"\n}" 
    sleep @api.time_between_calls
    new_id = JSON.parse(new_topic.body).dig('topicId')
    FORUM_MAP.info("TOPIC,#{new_id}")
    return new_id
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

  # not sure how to tie post responses to their post.. maybe just make one topic (from old community) and add all activity posts as responses?
  def get_wp_activity_posts(group_slug = 'agriculture-team')
    # wp_sfposts
    wp.query(<<-QUERY).to_a
    SELECT a.id post_id, a.content, u.display_name post_user, u.user_login, u.user_email, g.name, a.date_recorded, 
    gu.user_email group_user_email, gu.display_name group_creator
    FROM wp_bp_activity a 
    JOIN wp_users u ON u.id = a.user_id
    JOIN wp_bp_groups g ON g.id = a.item_id
    JOIN wp_users gu ON gu.id = g.creator_id
    WHERE a.component = 'groups' AND a.type = 'activity_update' AND g.slug = '#{group_slug}'
    ORDER BY a.date_recorded ASC
    QUERY
  end
  
  def get_wp_activity_post_comments(group_slug = 'agriculture-team')
    wp.query(<<-QUERY).to_a
      SELECT a.id comment_id, a.secondary_item_id parent_id, a.content, u.display_name post_user, u.user_login, u.user_email, g.name, a.date_recorded
      FROM wp_bp_activity a 
        JOIN wp_users u ON u.id = a.user_id
        JOIN wp_bp_activity parent ON parent.id = a.secondary_item_id
        JOIN wp_bp_groups g ON g.id = parent.item_id
        JOIN wp_bp_activity ac ON ac.secondary_item_id = a.id
      WHERE parent.component = 'groups' AND parent.type = 'activity_update' AND g.slug = 'climate-change-national-security'
      ORDER BY a.date_recorded desc
    QUERY
  end

end