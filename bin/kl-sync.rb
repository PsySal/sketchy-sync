#!/usr/bin/env ruby

require_relative '../lib/syncer'

folders_to_check =
	if ARGV.size > 0
		ARGV.dup
	else
		nil
	end

syncer = Syncer.new
syncer.sync_all_folders(folders_to_check)
