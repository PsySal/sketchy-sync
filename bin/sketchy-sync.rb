#!/usr/bin/env ruby

require_relative '../lib/sync_tester'
require_relative '../lib/syncer'

require 'slop'

# sync stdout so that progress messages are more likely to display correctly
STDOUT.sync = true if STDOUT.tty?

opts = Slop.parse do |o|
	o.string '--connect', 'Connect to an existing archive'
	o.bool '--test', 'Test connection to archive'
	o.bool '--create', 'Create a stub config, unless one already exists, and exit'
end

# stub is used by self test, always do this first
if opts[:create]
	SyncSettings.new
	exit 0
end

connect_remote_path = opts[:connect]
if connect_remote_path
	tester = SyncTester.new("#{connect_remote_path}/_TEST")
	unless tester.run_tests
		puts 'Tests failed; not connecting'
		exit -1
	end

	# todo: sync the .sync/sync_settings.yml file down, if we can

	exit 0
end

folders_to_check = opts.args
folders_to_check = nil if folders_to_check.empty?

syncer = Syncer.new

puts 'test' if opts[:test]

syncer.sync_all_folders(folders_to_check)

