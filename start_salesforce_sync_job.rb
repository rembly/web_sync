#!/usr/bin/env ruby
require_relative './lib/push_sync'

LOG = Logger.new(File.join(File.dirname(__FILE__), 'log', 'sync.log'))

p 'Listening for Salesforce Updates to Sync to Zoom...'
LOG.info('Listening for Salesforce Updates to Sync to Zoom...')
begin
  PushSync.new
rescue Exception => e
  p 'Salesforce Sync Process was Interrupted'
  LOG.error('Salesforce Sync Process was Interrupted')
end
