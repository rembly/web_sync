require_relative '../salesforce_sync'
require 'csv'


def get_confirmed
  # https://na51.salesforce.com/00O0V000005YQhM
  confirmed = CSV.readlines(File.join(File.dirname(__FILE__), '..', '..', 'data', 'appointment_setter_confirmed.csv'), headers: true)
  confirmed.map(&:to_hash)
end

def get_cong_districts
  # list of cong districts
  # https://na51.salesforce.com/00Od0000004IkRL/e?retURL=%2F00Od0000004IkRL
  dist = CSV.readlines(File.join(File.dirname(__FILE__), '..', '..', 'data', 'moc_with_districts.csv'), headers: true)
  dist = dist.map(&:to_hash)
end

def get_scheduled_meetings
  # already schedule meetings: https://na51.salesforce.com/00O0V000005IfeF
  meetings = CSV.readlines(File.join(File.dirname(__FILE__), '..', '..', 'data', 'already_scheduled_districts.csv'), headers: true)
  meetings = meetings.map(&:to_hash)
end


def get_missing_districts(meetings, dist)
  meeting_dist = meetings.map{|m| m['Congressional District']}.uniq
  # dist.select{|d| meeting_dist.exclude? d['Account/Organization Name: CCL Congressional District: Account/Organization Name']}
  missing = dist.select{|d| meeting_dist.exclude? d['Account/Organization Name: CCL Congressional District: Account/Organization Name']}
end

def get_missing_accounts(missing)
  sf = SalesforceSync.new
  missing_ids = missing.map{|m| m['Account/Organization Name: CCL Congressional District: Account/Organization ID']}
  missing_string = "('" + missing_ids.join("','") + "')"
  missing_accounts = sf.client.query("SELECT Id, CCL_Congressional_District__c,  Name, Office_Building__c, Office_Number__c FROM Account WHERE ID in #{missing_string}")
end

def get_tbd_rows(missing, missing_accounts, confirmed)
  missing_grouped = missing_accounts.group_by{|m| m.Name}
  confirmed_grouped = confirmed.group_by{|c| c['District/Org']}
  
  rows = missing.map do |m|
    dist_name = m['Account/Organization Name: CCL Congressional District: Account/Organization Name']
    moc = m['Contact ID']
    dist = missing_grouped[dist_name]&.first
    setter = confirmed_grouped[dist_name]&.first
    p dist
    setter = setter || {}
    [dist_name, dist&.Id, 'True', '6/11/2019 9:00 AM', 'Staff', dist&.Office_Building__c, dist&.Office_Number__c, moc,
      setter['Appt Setter: ID'], setter['Appointment Setter: Email'], 'a080V00001nNve4', 'TBD Created when no meeting scheduled by May 31st']
    end
  end
  
  def write_rows(rows)
    file = File.join(File.dirname(__FILE__), '..', '..', 'data', 'tbd_meetings.csv')
    CSV.open(file, 'w'){|csv| rows.each{|r| csv << r}}
  end

  def run_script
    confirmed = get_confirmed
    dist = get_cong_districts
    meetings = get_scheduled_meetings
    missing = get_missing_districts(meetings, dist)
    missing_accounts = get_missing_accounts(missing)
    rows = get_tbd_rows(missing, missing_accounts, confirmed)
    write_rows(rows)
  end