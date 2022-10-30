#!/usr/bin/env ruby

require 'open3'
require 'shellwords'

require_relative 'sync_db'
require_relative 'sync_settings'

# Synchronize files via rsync
class Syncer
	# sync a list of folders, or all first-level sub-folders in the current working directory
	# - if an explicit folder list is given, they will be created first
	def sync_all_folders(folders_to_check = nil)
		@settings = SyncSettings.new

		# sync stdout so that progress messages are more likely to display correctly
		STDOUT.sync = true

		# do we need to first create them?
		if folders_to_check
			_check_create_all_folders(folders_to_check)
		else
			folders_to_check = Dir.glob('*')
		end

		ljust_width = _compute_ljust_width(folders_to_check)

		# iterate all folders
		folders_to_check.each do |folder_name|
			folder_name = File.basename(folder_name)
			next if folder_name.include?('/')
			next if SyncSettings::DOT_SYNC_FOLDER == folder_name
			next unless File.directory?(folder_name)

			puts_prefix = folder_name.ljust(ljust_width, ' ')
			_sync_folder(puts_prefix, folder_name)
		end
	end

	private

	# ensure the input list of folders exist (and are directories), creating as needed
	def _check_create_all_folders(folders_to_check)
		folders_to_check.each do |folder_name|
			if File.exist? folder_name
				unless File.directory? folder_name
					puts "💀  ERROR: passed #{folder_name} on the commandline, which is not a folder"
					exit(-1)
				end
			else
				Dir.mkdir folder_name
			end
		end
	end

	# compute the maximum left-justification width so we can pretty-print
	def _compute_ljust_width(folders_to_check)
		ljust_width = 1
		folders_to_check.each do |folder_name|
			folder_name = File.basename(folder_name)
			next if folder_name.include?('/')
			next if SyncSettings::DOT_SYNC_FOLDER == folder_name
			next unless File.directory?(folder_name)

			ljust_width = [ljust_width, folder_name.length].max
		end
		ljust_width
	end

	# sync a given folder somewhat safely
	# - we first sync UP, then DOWN, using rsync
	# - when we sync UP, we only sync files since the last sync date, and only update files
	# - when we sync DOWN, we use -delete option; this allows moved/deleted files in source to propogate, but is a bit dangerous
	# - we keep track of a sync lockfile and timefile in a special .sync/ folder
	def _sync_folder(puts_prefix, folder_name)
		puts "#{puts_prefix}:🔒  creating lockfile"

		start_sync_ts = Time.now.to_i

		# create a lock file in .sync
		folder_lockfile = "#{SyncSettings::DOT_SYNC_FOLDER}/#{folder_name}.lock"
		if File.exist?(folder_lockfile)
			puts "#{puts_prefix}:💀  ERROR: folder lockfile #{folder_lockfile} exists; not syncing this folder."
			return false
		end
		File.open(folder_lockfile, 'w') do |f|
			f.write("This is a lock file for the folder #{folder_name}. This file means that a sync may be in progress, or one may have been interrupted.")
		end
		unless File.exist?(folder_lockfile)
			puts "#{puts_prefix}:💀  ERROR: could not create folder lockfile #{folder_lockfile}; not syncing this folder."
			return false
		end

		# initialize our file info db, for syncing
		file_sync_db = FileSyncDB.new(@settings, folder_name)

		# sync them up
		rsync_up_succeeded = _sync_folder_up(puts_prefix, folder_name, file_sync_db, start_sync_ts)

		# sync down, but only if there were no errors syncing up
		if rsync_up_succeeded
			rsync_down_succeeded = _sync_folder_down(puts_prefix, folder_name, file_sync_db, start_sync_ts)

			if rsync_down_succeeded
				puts "#{puts_prefix}:✅  Down-sync suceeded; files are up-to-date."
			else
				puts "#{puts_prefix}:💀  WARNING: there was an rsync error while down-syncing; files may not be up-to-date."
			end

			# another sleep after down sync
			puts "#{puts_prefix}:🌙  sleeping #{@settings.sleep_time} seconds"
			sleep @settings.sleep_time
		else
			puts "#{puts_prefix}:💀  WARNING: rsync failed while up-syncing; not syncing this folder down."
		end
	rescue SystemExit, Interrupt
		puts "#{puts_prefix}:💀  ERROR: rescued exit exception; exiting"
		raise
	rescue Exception => e
		puts "#{puts_prefix}:💀  ERROR: canceling folder due to rescued exception: #{e}: #{e.backtrace.join(', ')}"
	ensure
		puts "#{puts_prefix}:🔓  deleting lockfile"
		# always unlock the lock file in .sync; note that we won't have updated the timefile unless up-sync completed
		unless File.delete(folder_lockfile)
			puts "#{puts_prefix}:💀  WARNING: could not delete folder lockfile #{folder_lockfile} for folder #{folder_name}; sync may fail until this lockfile is removed"
		end
	end

	# capture and echo stdout/stderr (from Open3) in threads, joining them after
	def _capture_and_echo_io(prefix, stdout, stderr)
		newline_chars = ["\r", "\n"]
		stdout_thread = Thread.new do
			is_newline = true
			while c = stdout.getc
				print prefix if is_newline
				print c
				is_newline = (newline_chars.include? c)
			end
		end
		stderr_thread = Thread.new do
			is_newline = true
			while c = stderr.getc
				print prefix if is_newline
				print c
				is_newline = (newline_chars.include? c)
			end
		end
		stdout_thread.join
		stderr_thread.join
	end

	# sync a folder UP, using rsync
	# - this is called by sync_folder
	# - will not update timefile
	#
	# @param folder_name [String] the folder name to sync
	# @param file_sync_db [FileSyncDB] the file sync db object for this folder
	# @param start_sync_ts [Integer] the unix timestamp that this sync cycle was started
	# @return [Boolean] true if the folder was up-sync'd successfully, false
	#   otherwise
	def _sync_folder_up(puts_prefix, _folder_name, file_sync_db, start_sync_ts)
		# get all files nwer than the given date
		rsync_files = file_sync_db.update_file_info_and_find_all_files_to_up_sync!(puts_prefix, start_sync_ts)

		# start syncing
		puts "#{puts_prefix}: △ Up-syncing #{rsync_files.size} files"
		if rsync_files.size == 0
			puts "#{puts_prefix}: △ No new files; skipping"
			return true
		end

		# sync them up, echoing status
		rsync_upstream_folder = Shellwords.escape("#{@settings.upstream_folder}")
		rsync_cmd = "rsync #{@settings.rsync_dry_run} #{@settings.rsync_progress} --update --compress --times --perms --links --files-from=- . \"#{rsync_upstream_folder}\""
		puts "#{puts_prefix}: △ #{rsync_cmd}"
		rsync_status = Open3.popen3(ENV, rsync_cmd) do |stdin, stdout, stderr, wait_thread|
			rsync_files.each do |filename|
				stdin.puts(filename)
			end
			stdin.close
			_capture_and_echo_io("#{puts_prefix}: △ ", stdout, stderr)
			wait_thread.join
			wait_thread.value
		end

		# make sure at least @settings.sleep_time passes between rsync, but do it in a thread
		# so we count the time spent saving the shas file as sleep time
		sleep_thread = Thread.new do
			sleep @settings.sleep_time
		end

		# save the shas file if the rsync was a success
		if rsync_status.success?
			if @settings.rsync_dry_run.empty?
				puts "#{puts_prefix}:✅  Up-sync succeeded; saving the file info for this folder."
				file_sync_db.save_file_info
			else
				puts "#{puts_prefix}:✅  Up-sync succeeded, but operating in rsync dry-run mode; not saving the file info for this folder."
			end
		else
			puts "#{puts_prefix}:💀  WARNING: there was an rsync error while up-syncing; not saving the file info for this folder."
		end

		# sleep a short while; this is to prevent ssh thinking that's being flooded
		puts "#{puts_prefix}:🌙  sleeping #{@settings.sleep_time} seconds"
		sleep_thread.join

		# return true if the sync up worked
		rsync_status.success?
	end

	# sync a given folder DOWN, using rsync
	#
	# @param folder_name [String] the folder name to sync
	# @return [Boolean] true if folder was down-sync'd, false otherwise
	def _sync_folder_down(puts_prefix, folder_name, file_sync_db, start_sync_ts)
		rsync_upstream_folder = Shellwords.escape("#{@settings.upstream_folder}/#{folder_name}")
		rsync_cmd = "rsync #{@settings.rsync_dry_run} #{@settings.rsync_progress} #{@settings.rsync_delete} --update --exclude \"\\.*\" --compress --recursive --times --perms --links \"#{rsync_upstream_folder}\" ."
		puts "#{puts_prefix}: ▼ #{rsync_cmd}"
		rsync_status = Open3.popen3(ENV, rsync_cmd) do |_stdin, stdout, stderr, wait_thread|
			_capture_and_echo_io("#{puts_prefix}: ▼ ", stdout, stderr)
			wait_thread.join
			wait_thread.value
		end

		end_sync_ts = Time.now.to_i

		# refresh the file sync db with any updated files;
		# - note we do this regardless the downsync status, because we always want to be up to date here
		file_sync_db.update_file_info_after_down_sync!(puts_prefix, start_sync_ts, end_sync_ts)
		file_sync_db.save_file_info

		rsync_status.success?
	end
end
