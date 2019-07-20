#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative '../lib/swc_sync/swc_group_mapping'

begin
  sm = SwcGroupMapping.new
  sm.generate_group_mapping
rescue Exception => e
  message = "Failed to generate group mapping: #{e.message}: #{e.backtrace.inspect}"
  p message
end
