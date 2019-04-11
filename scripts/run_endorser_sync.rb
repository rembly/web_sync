#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/endorser_sync'
require_relative '../lib/web_sync/email_notifier'
LOG = Logger.new(File.join(File.dirname(__FILE__), '..', 'log', 'endorser_sync.log'))

begin
  sync = EndorserSync.new
  sync.sync_endorsers_to_get
  sync.sync_endorsers_to_wordpress
  sync = EndorserSync.new(use_production: true)
  sync.sync_endorsers_to_wordpress
rescue Exception => e
  message = "Failed to update waitlist sheet: #{e.message}: #{e.backtrace.inspect}"
  p message
  LOG.error(message)
  to = 'bryan.hermsen@citizensclimate.org'
  EmailNotifier.new.send_email(subject: 'Endorser Sync Failure', body: "Failed to sync endorsers: #{message}", to: to)
end
