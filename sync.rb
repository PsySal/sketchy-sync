#!/usr/bin/env ruby

require 'open3'
require 'shellwords'
require 'yaml'

# this is a special folder for lock files and timing files, and the settings file that controls where and how we sync
DOT_SYNC_FOLDER = '.sync'
SYNC_SETTINGS_BASENAME = 'sync_settings.txt'
SYNC_SETTINGS_FILENAME = "#{DOT_SYNC_FOLDER}/#{SYNC_SETTINGS_BASENAME}"

# if we're missing the .sync folder, create it, together with a placeholder sync_settings.txt (YAML) file
unless File.directory?(DOT_SYNC_FOLDER)
  begin
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

      # this will prevent any files actually being transferred
      # - set it it to No once you've done a test run or two and think things are probably OK
      # - useful for test runs
      rsync_dry_run: Yes

      # this controls whether or not rsync displays progress while syncing
      # - set it to No to squelch progress messages if they annoy you
      # - progress messages may work better or worse on some platforms (i.e., worse on Windows)
      rsync_progress: Yes

      # this tells sync.rb that you have configured this file
      # - set it to Yes once you've configured this file
      settings_are_set: No
      EOT
    end
  rescue Exception => e
    puts "ERROR: could not create #{DOT_SYNC_FOLDER} or #{SYNC_SETTINGS_FILENAME}"
    puts e
    exit -1
  end
end

# try to load the sync_settings.txt (YAML)
settings =
  begin
    YAML.load_file("#{SYNC_SETTINGS_FILENAME}")
  rescue Exception => e
    puts "ERROR: could not load settings from #{SYNC_SETTINGS_FILENAME}"
    puts e
    exit -1
  end

# load them into constants used by this script
UPSTREAM_FOLDER = settings['upstream_folder'].to_s
SLEEP_TIME = settings['sleep_time'].to_i
RSYNC_DRY_RUN = settings['rsync_dry_run'] ? '-n' : ''
RSYNC_PROGRESS = settings['rsync_progress'] ? '--progress' : ''
SETTINGS_ARE_SET = (settings['settings_are_set'] == true)

# check settings
unless SETTINGS_ARE_SET
  puts "ERROR: please edit #{SYNC_SETTINGS_FILENAME} with your sync settings, and set settings_are_set to Yes"
  exit -1
end

# make sure they specified an upstream folder
unless UPSTREAM_FOLDER && !UPSTREAM_FOLDER.empty?
  puts "ERROR: please specify upstream_folder in #{SYNC_SETTINGS_FILENAME}"
  exit -1
end

# make sure they specified a valid sleep time
unless SLEEP_TIME && SLEEP_TIME >= 0
  puts "ERROR: please specify sleep_time >= 0 in #{SYNC_SETTINGS_FILENAME}"
  exit -1
end

# print a warning if we're in dry run mode
unless RSYNC_DRY_RUN.empty?
  puts "💀  WARNING: executing in dry-run mode; not actually sync'ing anything"
end

# sync stdout so that progress messages are more likely to display correctly
STDOUT.sync = true

# capture and echo stdout/stderr (from Open3) in threads, joining them after
def capture_and_echo_io(prefix, stdout, stderr)
  newline_chars = [ "\r", "\n" ]
  stdout_thread = Thread.new do
    is_newline = true
    while c = stdout.getc do
      print prefix if is_newline
      print c
      is_newline = (newline_chars.include? c)
    end
  end
  stderr_thread = Thread.new do
    is_newline = true
    while c = stderr.getc do
      print prefix if is_newline
      print c
      is_newline = (newline_chars.include? c)
    end
  end
  stdout_thread.join
  stderr_thread.join
end

# recurse and find all files starting from the given folder
def find_files_newer_than(path, date)
  files = []
  Dir.glob("#{path}/*") do |f|
    if File.directory?(f)
      files += find_files_newer_than(f, date)
    elsif File.file?(f)
      unless File.basename(f).start_with?('.')
        if date.nil? || File.ctime(f) > date
          files << f
        end
      end
    else
      print "💀  WARNING: not adding file #{f}"
    end
  end
  files
end

# sync a folder UP, using rsync
# - this is called by sync_folder
# - will not update timefile
#
# @param folder_name [String] the folder name to sync
# @param newer_date [Time] the timestamp to limit files newer than, or nil for all files
# @return [Boolean] true if the folder was up-sync'd successfully, false otherwise
def sync_folder_up(puts_prefix, folder_name, newer_date = nil)
  # get all files nwer than the given date
  rsync_files = find_files_newer_than(folder_name, newer_date)

  # start syncing
  puts "#{puts_prefix}: △ Up-syncing #{rsync_files.size} files"
  if rsync_files.size == 0
    puts "#{puts_prefix}: △ No new files; skipping"
    return true
  end

  # sync them up, echoing status
  rsync_upstream_folder = Shellwords.escape("#{UPSTREAM_FOLDER}")
  rsync_cmd = "rsync #{RSYNC_DRY_RUN} #{RSYNC_PROGRESS} --update --compress --times --perms --links --files-from=- . \"#{rsync_upstream_folder}\""
  puts "#{puts_prefix}: △ #{rsync_cmd}"
  rsync_status = Open3.popen3(ENV, rsync_cmd) do |stdin, stdout, stderr, wait_thread|
    rsync_files.each do |filename|
      stdin.puts(filename)
    end
    stdin.close
    capture_and_echo_io("#{puts_prefix}: △ ", stdout, stderr)
    wait_thread.join
    wait_thread.value
  end

  # sleep a short while; this is to prevent ssh thinking that's being flooded
  puts "#{puts_prefix}:🌙  sleeping #{SLEEP_TIME} seconds"
  sleep SLEEP_TIME

  # return true if the sync up worked
  rsync_status.success?
end

# sync a given folder DOWN, using rsync
#
# @param folder_name [String] the folder name to sync
# @return [Boolean] true if folder was down-sync'd, false otherwise
def sync_folder_down(puts_prefix, folder_name)
  rsync_upstream_folder = Shellwords.escape("#{UPSTREAM_FOLDER}/#{folder_name}")
  rsync_cmd = "rsync #{RSYNC_DRY_RUN} #{RSYNC_PROGRESS} --update --delete --exclude \"\\.*\" --compress --recursive --times --perms --links \"#{rsync_upstream_folder}\" ."
  puts "#{puts_prefix}: ▼ #{rsync_cmd}"
  rsync_status = Open3.popen3(ENV, rsync_cmd) do |stdin, stdout, stderr, wait_thread|
    capture_and_echo_io("#{puts_prefix}: ▼ ", stdout, stderr)
    wait_thread.join
    wait_thread.value
  end

  rsync_status.success?
end

# sync a given folder somewhat safely
# - we first sync UP, then DOWN, using rsync
# - when we sync UP, we only sync files since the last sync date, and only update files
# - when we sync DOWN, we use -delete option; this allows moved/deleted files in source to propogate, but is a bit dangerous
# - we keep track of a sync lockfile and timefile in a special .sync/ folder
def sync_folder(puts_prefix, folder_name)
  puts "#{puts_prefix}:🔒  creating lockfile"

  # create a lock file in .sync
  folder_lockfile = "#{DOT_SYNC_FOLDER}/#{folder_name}_lock.txt"
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

  # get the list of files to sync UP
  # - we only want files since the last time we sync'd,
  # - otherwise, moving/deleting files on the upstream server will have no effect, since we always sync UP, then DOWN
  folder_timefile = "#{DOT_SYNC_FOLDER}/#{folder_name}_time.txt"
  newer_date =
    if File.file?(folder_timefile)
      File.ctime(folder_timefile)
    end

  # sync them up
  rsync_up_succeeded = sync_folder_up(puts_prefix, folder_name, newer_date)

  # write the time file
  if rsync_up_succeeded
    if RSYNC_DRY_RUN.empty?
      puts "#{puts_prefix}:✅  Up-sync succeeded; updating the timefile for this folder."
      File.open(folder_timefile, 'w') do |f|
        f.write("This is a time file for the folder #{folder_name}. The creation/modification time of this file represents the last time this folder was synced.")
      end
    else
      puts "#{puts_prefix}:✅  Up-sync succeeded, but operating in rsync dry-run mode; not updating the timefile for this folder."
    end
  else
    puts "#{puts_prefix}:💀  WARNING: there was an rsync error while up-syncing; not updating the timefile for this folder."
  end

  # sync down, but only if there were no errors syncing up
  unless rsync_up_succeeded
    puts "#{puts_prefix}:💀  WARNING: rsync failed while up-syncing; not syncing this folder down."
  else
    rsync_down_succeeded = sync_folder_down(puts_prefix, folder_name)

    if rsync_down_succeeded
      puts "#{puts_prefix}:✅  Down-sync suceeded; files are up-to-date."
    else
      puts "#{puts_prefix}:💀  WARNING: there was an rsync error while down-syncing; files may not be up-to-date."
    end

    # another sleep after down sync
    puts "#{puts_prefix}:🌙  sleeping #{SLEEP_TIME} seconds"
    sleep SLEEP_TIME
  end
rescue SystemExit, Interrupt
  puts "#{puts_prefix}:💀  ERROR: rescued exit exception; exiting"
  raise
rescue Exception => e
  puts "#{puts_prefix}:💀  ERROR: rescued exception #{e}; canceling this folder, but will try to continue"
ensure
  puts "#{puts_prefix}:🔓  deleting lockfile"
  # always unlock the lock file in .sync; note that we won't have updated the timefile unless up-sync completed
  unless File.delete(folder_lockfile)
    puts "#{puts_prefix}:💀  WARNING: could not delete folder lockfile #{folder_lockfile} for folder #{folder_name}; sync may fail until this lockfile is removed"
  end
end

# did they specify a list of folders on the commandline?
folders_to_check =
  if ARGV.size > 0
    ARGV.dup
  else
    Dir.glob('*')
  end

# get maximum ljust width so it prints nicely
ljust_width = 1
folders_to_check.each do |folder_name|
  folder_name = File.basename(folder_name)
  next if folder_name.include?('/')
  next unless File.directory?(folder_name)
  next if DOT_SYNC_FOLDER == folder_name

  ljust_width = [ljust_width, folder_name.length].max
end

# iterate all folders
folders_to_check.each do |folder_name|
  folder_name = File.basename(folder_name)
  next if folder_name.include?('/')
  next unless File.directory?(folder_name)
  next if DOT_SYNC_FOLDER == folder_name

  puts_prefix = folder_name.ljust(ljust_width, ' ')
  sync_folder(puts_prefix, folder_name)
end
