#!/usr/bin/env ruby
require_relative './lib/salesforce_zoom_sync'

Process.setproctitle('nightly_sync')

LOG = Logger.new(File.join(File.dirname(__FILE__), 'log', 'nightly_sync.log'))
p '****** Running daily SF to Zoom Sync ******'
LOG.info('Running sync job...')
begin
  SalesforceZoomSync.new.run_sf_to_zoom_sync
rescue Exception => e
  p "Daily SF to Zoom Sync Job Failed: #{e.message}"
  p e.backtrace.inspect
  LOG.error("Daily SF to Zoom Sync Job Failed: #{e.message}")
  LOG.error(e.backtrace.inspect)
end