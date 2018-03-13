#!/usr/bin/env ruby
require_relative './lib/salesforce_zoom_sync'

Process.setproctitle('nightly_sync')

LOG = Logger.new(File.join(File.dirname(__FILE__), 'log', 'nightly_sync.log'))

p 'Running sync job...'
LOG.info('Running sync job...')
begin
  SalesforceZoomSync.new
rescue Exception => e
  p "Nightly Sync Job Failed: #{e.message}"
  p e.backtrace.inspect
  LOG.error("Nightly Sync Job Failed: #{e.message}")
  LOG.error(e.backtrace.inspect)
end
