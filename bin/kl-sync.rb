#!/usr/bin/env ruby

require_relative '../lib/syncer'

require 'slop'

opts = Slop.parse do |o|
	o.string '--connect', 'Connect to an existing archive'
	o.bool '--test', 'Test connection to archive'
end

folders_to_check = opts.args
folders_to_check = nil if folders_to_check.empty?

#folders_to_check =
#	if ARGV.size > 0
#		ARGV.dup
#	else
#		nil
#	end

p folders_to_check

syncer = Syncer.new
#syncer.sync_all_folders(folders_to_check)
