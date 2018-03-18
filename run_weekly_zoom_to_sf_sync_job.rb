#!/usr/bin/env ruby
require_relative './lib/salesforce_zoom_sync'

Process.setproctitle('weekly_sync')

LOG = Logger.new(File.join(File.dirname(__FILE__), 'log', 'weekly_sync.log'))
p '****** Running weekly sync ******'
p 'Killing push job...'
`pkill -f salesforce_push_sync`
LOG.info('Running weekly Zoom to SF sync job...')
begin
  SalesforceZoomSync.new.run_zoom_to_sf_sync
rescue Exception => e
  p "Weekly Zoom to SF Sync Job Failed: #{e.message}"
  p e.backtrace.inspect
  LOG.error("Weekly Zoom to SF Sync Job Failed: #{e.message}")
  LOG.error(e.backtrace.inspect)
end
