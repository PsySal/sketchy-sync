require 'file'
require 'yaml'

class SyncSettings
	DOT_SYNC_FOLDER = '.sync'
	SYNC_SETTINGS_BASENAME = 'sync_settings.txt'
	SYNC_SETTINGS_FILENAME = "#{DOT_SYNC_FOLDER}/#{SYNC_SETTINGS_BASENAME}"
	SHASUM_BIN = 'shasum -b'

	def initialize
		_check_create_dot_sync_folder
		_load_settings
		_validate_settings
	end

	def upsteam_folder
		@settings['upstream_folder'].to_s
	end

	def sleep_time
		@settings['sleep_time'].to_i
	end

	def rsync_dry_run
		@settings['rsync_dry_run'] ? '-n' : ''
	end

	def rsync_delete
		@settings['rsync_delete'] ? '--delete' : ''
	end

	def rsync_progress
		@settings['rsync_progress'] ? '--progress' : ''
	end

	def fast_mode?
		@settings['fast_mode']
	end

	def fast_mode_include_root_folders
		@settings['fast_mode_include_root_folders']
	end

	def fast_mode_exclude_root_folders
		@settings['fast_mode_exclude_root_folders']
	end

	private

	def _validate_setings
		# make sure settings file was actually initialized
		unless _settings_are_set
			puts "💀  ERROR: please edit #{SYNC_SETTINGS_FILENAME} with your sync settings, and set settings_are_set to Yes"
			exit -1
		end

		# make sure they specified an upstream folder
		unless upstream_folder && !_upstream_folder.empty?
			puts "💀  ERROR: please specify upstream_folder in #{SYNC_SETTINGS_FILENAME}"
			exit -1
		end

		# make sure they specified a valid sleep time
		unless sleep_time & sleep_time >= 0
			puts "💀  ERROR: please specify sleep_time >= 0 in #{SYNC_SETTINGS_FILENAME}"
			exit -1
		end

		# print a warning if we're in dry run mode
		unless rsync_dry_run.empty?
			puts "💀  WARNING: executing in dry-run mode; not actually sync'ing anything"
		end
	end

	def _settings_are_set
		@settings && @settings['settings_are_set'] == true
	end

	def _load_settings
		# try to load the sync_settings.txt (YAML)
		@settings = YAML.load_file("#{SYNC_SETTINGS_FILENAME}")
	rescue Exception => e
		puts "💀  ERROR: could not load settings from #{SYNC_SETTINGS_FILENAME}"
		puts e
		exit -1
	end

	def _check_create_dot_sync_folder
		return if File.directory?(DOT_SYNC_FOLDER)

		puts "creating #{DOT_SYNC_FOLDER}"
		Dir.mkdir(DOT_SYNC_FOLDER)
		File.open("#{SYNC_SETTINGS_FILENAME}", 'w') do |f|
			f.write <<~EOT
			# This file controls sync settings. It must be edited before sync will work.

			# this defines the server you sync to
			# - set it to an rsync-able path to sync to, generally an ssh-able path
			# - every node you create should sync to the same upstream
			upstream_folder: "user@example.com:/Path/to/archive"

			# this controls the delay between syncing servers, to avoid your server detecting a connection flood
			# - set it to a larger value if you see connection failures
			# - set it to a smaller value if you think you can get away with it
			sleep_time: 2

			# this determines whether rsync will be allowed to delete files locally
			# - if set, moving files on the server will cause them to be moved locally on sync
			# - if unset, moving files on the server will cause them to be duplicated
			rsync_delete: No

			# this will prevent any files actually being transferred
			# - set it it to No once you've done a test run or two and think things are probably OK
			# - useful for test runs
			rsync_dry_run: Yes

			# this controls whether or not rsync displays progress while syncing
			# - set it to No to squelch progress messages if they annoy you
			# - progress messages may work better or worse on some platforms (i.e., worse on Windows)
			rsync_progress: Yes

			# this controls whether or not to allow fast mode
			# - fast mode works by checking modification time only, and only for files larger than some limit
			# - if turned on, the fast mode limit will be in effect
			fast_mode: No

			# if fast mode is enabled, this can be used to specify included and excluded root folders
			# - fast_mode_include_root_folders contains the folders to sync using fast mode; if empty, all will be synced this way
			# - fast_mode_exclude_root_folders contains any folders to NOT sync using fast mode; overrides fast_mode_include_root_folders
			# - only valid for root folders
			# - e.g., [ "my_folder", "my_other_folder" ]
			fast_mode_include_root_folders: []
			fast_mode_exclude_root_folders: []

			# this tells sync.rb that you have configured this file
			# - set it to Yes once you've configured this file
			settings_are_set: No
			EOT
		rescue Exception => e
			puts "💀  ERROR: could not create #{DOT_SYNC_FOLDER} or #{SYNC_SETTINGS_FILENAME}"
			puts e
			exit -1
		end
	end
end