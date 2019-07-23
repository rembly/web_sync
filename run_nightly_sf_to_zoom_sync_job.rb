#!/usr/bin/env ruby
require_relative './lib/salesforce_zoom_sync'
require_relative './lib/web_sync/email_notifier'

Process.setproctitle('nightly_sync')

LOG = Logger.new(File.join(File.dirname(__FILE__), 'log', 'nightly_sync.log'))
p '****** Running daily SF to Zoom Sync ******'
LOG.info('Running sync job...')
p 'Killing push job...'
`pkill -f salesforce_push_sync`
begin
  sync = SalesforceZoomSync.new
  sync.run_sf_to_zoom_sync
  sync.run_ocat_zoom_to_sf_sync
rescue Exception => e
  message = "Daily SF to Zoom Sync Job Failed: #{e.message}"
  backtrace = e.backtrace.inspect
  p message
  p backtrace
  LOG.error("Daily SF to Zoom Sync Job Failed: #{e.message}")
  LOG.error(backtrace)
  to = 'bryan.hermsen@citizensclimate.org'
  EmailNotifier.new.send_email(subject: 'Nightly SF to Zoom Sync Failure', 
    body: "Failed to complete nightly sync: #{message}\nBacktrace: #{backtrace}", to: to)
end
