#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/swc_sync/group_sync'
require_relative '../lib/web_sync/email_notifier'
LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'swc_group_sync.log'))

begin
  LOG.info('Starting SWC Group Zip Sync...')
  GroupSync.new.update_address
  LOG.info('Ending SWC Group Zip Sync...')
rescue Exception => e
  message = "Failed to complete SWC Group Zip Sync: #{e.message}: #{e.backtrace.inspect}"
  p message
  LOG.error(message)
  to = 'bryan.hermsen@citizensclimate.org'
  EmailNotifier.new.send_email(subject: 'SWC Group Zip Sync Failure', body: "Failed to sync swc group zip codes: #{message}", to: to)
end
