# frozen_string_literal: true
require 'active_support/all'
require 'pry'
require 'csv'
require_relative '../salesforce_sync'

class DonationReports
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'donation_reports.log'))
  NEW_DONORS_RAW = File.join(File.dirname(__FILE__), '..', '..', 'data', 'new_donors_raw.csv')

  attr_accessor :sf

  def initialize
    @sf = SalesforceSync.new
  end

  def build_new_donor_report

  end

  def write_donors
    CSV.open(NEW_DONORS_RAW, 'w') do |csv|
      csv << ['Opportunity Id', 'Account Id', 'First Donation', 'First Donation Year', 'Amount', 'Close Date', 'Close Year']
      get_new_donors_since.each do |donation|
        csv << [donation.Id, donation.Account.Id, donation.Account.npo02__FirstCloseDate__c, donation.Account.npo02__FirstCloseDate__c.to_date.year,
          donation.Amount, donation.CloseDate, donation.CloseDate.to_date.year]
      end
    end
  end

  def get_new_donors_since(since: Date.new(2015))
    # Stage: Awarded, Closed Won
    # Close date >= .., transaction type = donation

    sf.client.query(<<-QUERY)
      SELECT Id, Account.Id, Account.npo02__FirstCloseDate__c, Amount, CloseDate
      FROM Opportunity
      WHERE StageName IN ('Closed Won') AND CloseDate >= #{since} AND Account.npo02__FirstCloseDate__c >= #{since} 
        AND stayclassy__Transaction_Type__c = 'Donation'
      QUERY
      # WHERE StageName IN ('Awarded', 'Closed Won') AND CloseDate >= #{since} AND Account.npo02__FirstCloseDate__c >= #{since}
  end

end