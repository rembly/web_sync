require_relative '../salesforce_sync'
require 'csv'
require 'pry'


def get_cong_districts
  # list of cong districts
  # https://na51.salesforce.com/00Od0000004IkRL/e?retURL=%2F00Od0000004IkRL
  dist = CSV.readlines(File.join(File.dirname(__FILE__), '..', '..', 'data', 'moc_with_districts.csv'), headers: true)
  dist = dist.map(&:to_hash)
end

def get_meeting_plans
  # already schedule meetings: https://na51.salesforce.com/00O0V000005YSVD
  plans = CSV.readlines(File.join(File.dirname(__FILE__), '..', '..', 'data', 'meeting_plans_2019.csv'), headers: true)
  plans = plans.map(&:to_hash)
end


def get_missing_districts(plans, dist)
  plan_dist = plans.map{|m| m['District']}.uniq
  missing = dist.select{|d| plan_dist.exclude? d['Account/Organization Name: CCL Congressional District: Account/Organization Name']}
end

def get_missing_accounts(missing)
  sf = SalesforceSync.new
  missing_ids = missing.map{|m| m['Account/Organization Name: CCL Congressional District: Account/Organization ID']}
  missing_string = "('" + missing_ids.join("','") + "')"
  missing_accounts = sf.client.query("SELECT Id, CCL_Congressional_District__c,  Name, Office_Building__c, Office_Number__c FROM Account WHERE ID in #{missing_string}")
end

def get_plan_rows(missing, missing_accounts)
  missing_grouped = missing_accounts.group_by{|m| m.Name}
  
  rows = missing.map do |m|
    dist_name = m['Account/Organization Name: CCL Congressional District: Account/Organization Name']
    dist = missing_grouped[dist_name]&.first
    [dist_name, dist&.Id, 'True', 'a080V00001nNve4', m['Contact ID'], '2019']
    end
  end
  
  def write_rows(rows)
    file = File.join(File.dirname(__FILE__), '..', '..', 'data', 'empty_meeting_plans.csv')
    CSV.open(file, 'w'){|csv| rows.each{|r| csv << r}}
  end

  def run_script
    dist = get_cong_districts
    plans = get_meeting_plans
    missing = get_missing_districts(plans, dist)
    missing_accounts = get_missing_accounts(missing)
    rows = get_plan_rows(missing, missing_accounts)
    write_rows(rows)
  end