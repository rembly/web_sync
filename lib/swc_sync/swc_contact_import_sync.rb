# frozen_string_literal: true
require 'active_support/all'
require 'pry'
require_relative '../web_sync/json_web_token'
require_relative '../web_sync/throttled_api_client'
require_relative '../salesforce_sync'

class SwcContactImportSync
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'swc_contact_import.log'))
  CONTACT_IMPORT_FILE_LOCATION = File.join(File.dirname(__FILE__), '..', '..', 'data', 'contact_import.json')
  CONTACTS_TO_CLEAR_FILE_LOCATION = File.join(File.dirname(__FILE__), '..', '..', 'data', 'contact_import_to_clear.json')
  PROD_USERS = File.join(File.dirname(__FILE__), '..', '..', 'data', 'external_reference_users.json')
  STAGING_USERS = File.join(File.dirname(__FILE__), '..', '..', 'data', 'all_staging_users_2_1.json')
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

  def tie_user_groups
    # get users from SF with group info
    sf_users = get_sf_community_users
    # build map of swc_id to swc_group_id
    sf_groups = sf_users.each_with_object({}){|sf_user, map| map[sf_user.SWC_User_ID__c&.to_i] = sf_user.Group_del__r&.SWC_Group_ID__c&.to_i}

    # swc_users = api.call(endpoint: 'users?activeOnly=false&embed=groups')
    # use *pre-downloaded* list of users with group info to screen for users who already have their groups
    swc_users = JSON.parse(File.read(STAGING_USERS))
    # map of community users to the groups they are already in
    user_groups = swc_users.each_with_object({}){|user, map| map[user['userId']] = user['groups']}

    # which users are not already in their group
    need_tied = sf_groups.select{|id, group_id| user_groups.dig(id.to_s).to_a.exclude?(group_id.to_s)}
    p "#{need_tied.size} users need updated with group info.."
    LOG.info("#{need_tied.size} users need updated with group info..")

    need_tied.each do |swc_id, group_id|
      api.post(endpoint: "groups/#{group_id}/members", data: {userId: swc_id, status: 1})
      sleep 0.4
      message = "#{swc_id}, #{group_id} - tied"
      LOG.info(message)
      p message
    end
  end

  def build_user_export(limit = 1000)
    # we could capture current user groups with /users?limit=10&activeOnly=false&embed=groups
    # TODO: also caputre action teams
    # action_teams = api.call(endpoint:'groups', params: {categoryId: 5})
    # action_team_members = action_team_ids.map{|team_id| call(endpoint: "groups/#{team_id}/members", params: {embed: 'user'})}
    # action_team_admins = action_team_members.flatten.select{|member| member['status'].to_i > 1}.map{|admin| admin['user']}

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
    sf_users = get_sf_community_users
    sf_users.each{|user| set_user_profile_fields(user); sleep MAX_CALLS_PER_SECOND}
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
    binding.pry if sf_user.SWC_User_ID__c.to_i == 0
    results
  end

  def clear_contacts
    # to_clear = JSON.parse(File.read(CONTACTS_TO_CLEAR_FILE_LOCATION))
    # emails = to_clear.map{|u| u['*_email_address']}
    # swc_users = api.call(endpoint: 'users?activeOnly=false&embed=externalReferences')
    # swc_users = JSON.parse(File.read(PROD_USERS))
    ["17916","17917","17918","17919","17920","17921","17922","17923","17924","17925","17926","17927","17928","17929","17930","17931","17932","17933","17934","17935","17936","17937","17938","17939","17940","17941","17942","17943","17944","17945","17946","17947","17948","17949","17950","17951","17952","17953","17954","17955","17956","17957","17958","17959","17960","17961","17962","17963","17964","17965","17966","17967","17968","17969","17970","17971","17972","17973","17974","17975","17976","17977","17978","17979","17980","17981","17982","17983","17984","17985","17986","17987","17988","17989","17990","17991","17992","17993","17994","17995","17996","17997","17998","17999","18000","18001","18002","18003","18004","18005","18006","18007","18008","18009","18010","18011","18012","18013","18014","18015","18016","18017","18018","18019","18020","18021","18022","18023","18024","18025","18026","18027","18028","18029","18030","18031","18032","18033","18034","18035","18036","18037","18038","18039","18040","18041","18042","18043","18044","18045","18046","18047","18048","18049","18050","18051","18052","18053","18054","18055","18056","18057","18058","18059","18060","18061","18062","18063","18064","18065","18066","18067","18068","18069","18070","18071","18072","18073","18074","18075","18076","18077","18078","18079","18080","18081","18082","18083","18084","18085","18086","18087","18088","18089","18090","18091","18092","18093","18094","18095","18096","18097","18098","18099","18100","18101","18102","18103","18104","18105","18106","18107","18108","18109","18110","18111","18112","18113","18114","18115","18116","18117","18118","18119","18120","18121","18122","18123","18124","18125","18126","18127","18128","18129","18130","18131","18132","18133","18134","18135","18136","18137","18138","18139","18140","18141","18142","18143","18144","18145","18146","18147","18148","18149","18150","18151","18152","18153","18154","18155","18156","18157","18158","18159","18160","18161","18162","18163","18164","18165","18166","18167","18168","18169","18170","18171","18172","18173","18174","18175","18176","18177","18178","18179","18180","18181","18182","18183","18184","18185","18186","18187","18188","18189","18190","18191","18192","18193","18194","18195","18196","18197","18198","18199","18200","18201","18202","18203","18204","18205","18206","18207","18208","18209","18210","18211","18212","18213","18214","18215","18216","18217","18218","18219","18220","18221","18222","18223","18224","18225","18226","18227","18228","18229","18230","18231","18232","18233","18234","18235","18236","18237","18238","18239","18240","18241","18242","18243","18244","18245","18246","18247","18248","18249","18250","18251","18252","18253","18254","18255","18256","18257","18258","18259","18260","18261","18262","18263","18264","18265","18266","18267","18268","18269","18270","18271","18272","18273","18274","18275","18276","18277","18278","18279","18280","18281","18282","18283","18284","18285","18286","18287","18288","18289","18290","18291","18292","18293","18294","18295","18296","18297","18298","18299","18300","18301","18302","18303","18304","18305","18306","18307","18308","18309","18310","18311","18312","18313","18314","18315","18316","18317","18318","18319","18320","18321","18322","18323","18324","18325","18326","18327","18328","18329","18330","18331","18332","18333","18334","18335","18336","18337","18338","18339","18340","18341","18342","18343","18344","18345","18346","18347","18348","18349","18350","18351","18352","18353","18354","18355","18356","18357","18358","18359","18360","18361","18362","18363","18364","18365","18366","18367","18368","18369","18370","18371","18372","18373","18374","18375","18376","18377","18378","18379","18380","18381","18382","18383","18384","18385","18386","18387","18388","18389","18390","18391","18392","18393","18394","18395","18396","18397","18398","18399","18400","18401","18402","18403","18404","18405","18406","18407","18408","18409","18410","18411","18412","18413","18414","18415","18416","18417","18418","18419","18420","18421","18422","18423","18424","18425","18426","18427","18428","18429","18430","18431","18432","18433","18434","18435","18436","18437","18438","18439","18440","18441","18442","18443","18444","18445","18446","18447","18448","18449","18450","18451","18452","18453","18454","18455","18456","18457","18458","18459","18460","18461","18462","18463","18464","18465","18466","18467","18468","18469","18470","18471","18472","18473","18474","18475","18476","18477","18478","18479","18480","18481","18482","18483","18484","18485","18486","18487","18488","18489","18490","18491","18492","18493","18494","18495","18496","18497","18498","18499","18500","18501","18502","18503","18504","18505","18506","18507","18508","18509","18510","18511","18512","18513","18514","18515","18516","18517","18518","18519","18520","18521","18522","18523","18524","18525","18526","18527","18528","18529","18530","18531","18532","18533","18534","18535","18536","18537","18538","18539","18540","18541","18542","18543","18544","18545","18546","18547","18548","18549","18550","18551","18552","18553","18554","18555","18556","18557","18558","18559","18560","18561","18562","18563","18564","18565","18566","18567","18568","18569","18570","18571","18572","18573","18574","18575","18576","18577","18578","18579","18580","18581","18582","18583","18584","18585","18586","18587","18588","18589","18590","18591","18592","18593","18594","18595","18596","18597","18598","18599","18600","18601","18602","18603","18604","18605","18606","18607","18608","18609","18610","18611","18612","18613","18614","18615","18616","18617","18618","18619","18620","18621","18622","18623","18624","18625","18626","18627","18628","18629","18630","18631","18632","18633","18634","18635","18636","18637","18638","18639","18640","18641","18642","18643","18644","18645","18646","18647","18648","18649","18650","18651","18652","18653","18654","18655","18656","18657","18658","18659","18660","18661","18662","18663","18664","18665","18666","18667","18668","18669","18670","18671","18672","18673","18674","18675","18676","18677","18678","18679","18680","18681","18682","18683","18684","18685","18686","18687","18688","18689","18690","18691","18692","18693","18694","18695","18696","18697","18698","18699","18700","18701","18702","18703","18704","18705","18706","18707","18708","18709","18710","18711","18712","18713","18714","18715","18716","18717","18718","18719","18720","18721","18722","18723","18724","18725","18726","18727","18728","18729","18730","18731","18732","18733","18734","18735","18736","18737","18738","18739","18740","18741","18742","18743","18744","18745","18746","18747","18748","18749","18750","18751","18752","18753","18754","18755","18756","18757","18758","18759","18760","18761","18762","18763","18764","18765","18766","18767","18768","18769","18770","18771","18772","18773","18774","18775","18776","18777","18778","18779","18780","18781","18782","18783","18784","18785","18786","18787","18788","18789","18790","18791","18792","18793","18794","18795","18796","18797","18798","18799","18800","18801","18802","18803","18804","18805","18806","18807","18808","18809","18810","18811","18812","18813","18814","18815","18816","18817","18818","18819","18820","18821","18822","18823","18824","18825","18826","18827","18828","18829","18830","18831","18832","18833","18834","18835","18836","18837","18838","18839","18840","18841","18842","18843","18844","18845","18846","18847","18848","18849","18850","18851","18852","18853","18854","18855","18856","18857","18858","18859","18860","18861","18862",
      "18863","18864","18865","18866","18867","18868","18869","18870"].each do |user_id|
        api.send_delete(endpoint: "users/#{user_id}");
        sleep MAX_CALLS_PER_SECOND;
      end
    # groups_to_delete.each{|g| send_delete(endpoint: "groups/#{g['id']}");sleep MAX_CALLS_PER_SECOND}
  end

  # NOTE: this does not grab contacts who are not part of a chapter or part of a chapter without a SWC ID
  def get_sf_community_users
    return @sf_contacts if @sf_contacts
    @sf_contacts = sf.client.query(<<-QUERY)
      SELECT Id, FirstName, LastName, Email, SWC_User_ID__c, CCL_Community_Username__c, Group_del__c, Group_del__r.SWC_Group_ID__c,
        Congressional_District_Short_Name__c, Region__c, Group_Name__c, MailingPostalCode, Country_Full_Name__c, MailingState, MailingCity 
      FROM Contact 
      WHERE CCL_Community_Username__c <> '' AND SWC_User_ID__c <> 0 AND Group_del__c <> '' AND SWC_User_ID__c <> null
        AND Group_del__r.SWC_Group_ID__c <> 0 AND Group_del__r.SWC_Group_ID__c <> null
    QUERY
    @sf_contacts
  end
end