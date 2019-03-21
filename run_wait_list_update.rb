#!/usr/bin/env ruby
require_relative './lib/wait_list_update'
LOG = Logger.new(File.join(File.dirname(__FILE__), 'log', 'google_sync.log'))

begin
  sync = WaitListUpdate.new
  sync.update_sheet
rescue Exception => e
  p "Failed to update waitlist sheet: #{e.message}"
  p e.backtrace.inspect
  LOG.error("Failed to update waitlist sheet: #{e.message}")
  LOG.error(e.backtrace.inspect)
end