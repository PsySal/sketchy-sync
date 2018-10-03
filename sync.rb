#!/usr/bin/env ruby

require 'open3'
require 'shellwords'
require 'yaml'
require 'tempfile'
require 'pathname'

# this is a special folder for lock files and timing files, and the settings file that controls where and how we sync
DOT_SYNC_FOLDER = '.sync'
SYNC_SETTINGS_BASENAME = 'sync_settings.txt'
SYNC_SETTINGS_FILENAME = "#{DOT_SYNC_FOLDER}/#{SYNC_SETTINGS_BASENAME}"
SHASUM_BIN = 'shasum -b'
TEST_SHASUM = true

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

      # if fast mode is enabled, this can be used to specify excluded root folders
      # - folders listed here will never sync using fast mode
      # - only valid for root folders
      # - e.g., [ "my_folder", "my_other_folder" ]
      fast_mode_exclude_root_folders: []

      # if fast mode is enabled, this is the limit in mb to enable it for
      # - a limit of 0 means to use fast mode for all files
      fast_mode_file_size_limit_mb: 10

      # this tells sync.rb that you have configured this file
      # - set it to Yes once you've configured this file
      settings_are_set: No
      EOT
    end
  rescue Exception => e
    puts "💀  ERROR: could not create #{DOT_SYNC_FOLDER} or #{SYNC_SETTINGS_FILENAME}"
    puts e
    exit -1
  end
end

# try to load the sync_settings.txt (YAML)
settings =
  begin
    YAML.load_file("#{SYNC_SETTINGS_FILENAME}")
  rescue Exception => e
    puts "💀  ERROR: could not load settings from #{SYNC_SETTINGS_FILENAME}"
    puts e
    exit -1
  end

# load them into constants used by this script
UPSTREAM_FOLDER = settings['upstream_folder'].to_s
SLEEP_TIME = settings['sleep_time'].to_i
RSYNC_DRY_RUN = settings['rsync_dry_run'] ? '-n' : ''
RSYNC_DELETE = settings['rsync_delete'] ? '--delete' : ''
RSYNC_PROGRESS = settings['rsync_progress'] ? '--progress' : ''
FAST_MODE = settings['fast_mode']
FAST_MODE_EXCLUDE_ROOT_FOLDERS = settings['fast_mode_exclude_root_folders']
FAST_MODE_FILE_SIZE_LIMIT = settings['fast_mode_file_size_limit_mb'].to_i * 1024 * 1024
SETTINGS_ARE_SET = (settings['settings_are_set'] == true)

# check settings
unless SETTINGS_ARE_SET
  puts "💀  ERROR: please edit #{SYNC_SETTINGS_FILENAME} with your sync settings, and set settings_are_set to Yes"
  exit -1
end

# make sure they specified an upstream folder
unless UPSTREAM_FOLDER && !UPSTREAM_FOLDER.empty?
  puts "💀  ERROR: please specify upstream_folder in #{SYNC_SETTINGS_FILENAME}"
  exit -1
end

# make sure they specified a valid sleep time
unless SLEEP_TIME && SLEEP_TIME >= 0
  puts "💀  ERROR: please specify sleep_time >= 0 in #{SYNC_SETTINGS_FILENAME}"
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

# parse file shas from a given list of text file
# - can be used to parse the output of shasum, as well
# @return [Hash<String, String>] mapping filename => sha256
def load_file_shas(source_file)
  file_shas = {}
  source_file.each do |source_file_line|
    source_file_line.chomp!
    source_file_sha = source_file_line[0..39] # get the sha
    source_file_star = source_file_line[41..41]
    source_file_path = source_file_line[42..-1] # skip space, binary "*" prefix
    unless '*' == source_file_star && source_file_sha =~ /\A\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\z/
      puts "💀  ERROR: could not load shas; bad shas file or shasum binary '#{SHASUM_BIN}' does not work as expected"
      exit -1
    end
    file_shas[source_file_path] = source_file_sha.downcase
  end
  file_shas
end

# for the given list of filenames, return a hash filename => sha
# - this just calls shasum with these files as input, and parses the output
def get_file_shas(puts_prefix, filenames)
  # as a special case, if we have no filenames, return the empty list; if we
  # call shasum without arguments, it won't terminate
  return {} if filenames.empty?
  filenames_escaped = filenames.map do |filename|
    Shellwords.escape(filename)
  end
  shasum_stdout = ''
  until filenames_escaped.empty?
    some_filenames_escaped = filenames_escaped.take(100)
    filenames_escaped = filenames_escaped.drop(100)
    num_filenames_processed = filenames.size - filenames_escaped.size
    print "#{puts_prefix}: △ calculated shas for #{num_filenames_processed} / #{filenames.size} files\r" unless puts_prefix.nil?
    shasum_cmd = "#{SHASUM_BIN} #{some_filenames_escaped.join(' ')}"
    shasum_stdout += `#{shasum_cmd}`
  end
  print "\n" unless puts_prefix.nil?

  # shasum_cmd = "#{SHASUM_BIN} #{filenames_escaped.join(' ')}"
  # shasum_stdout = `#{shasum_cmd}`
  load_file_shas(shasum_stdout.split("\n"))
end

# test shasum to make sure it works as expected
if TEST_SHASUM
  sync_temp_file = Tempfile.new('sync temp')
  sync_temp_file.write('sync')
  sync_temp_file_path = sync_temp_file.path
  sync_temp_file_shas = get_file_shas(nil, [sync_temp_file_path])
  unless 'da39a3ee5e6b4b0d3255bfef95601890afd80709' == sync_temp_file_shas[sync_temp_file_path]
    puts "💀  ERROR: shasum binary '#{SHASUM_BIN}' does not work as expected; cannot proceed"
    exit -1
  end
end

# helper class; this represents a file information database, for storing shas and/or file sizes for a single root folder
class FileSyncDB
  def initialize(folder_name)
    @folder_name = folder_name
    @file_info_filename = "#{DOT_SYNC_FOLDER}/#{folder_name}_info.txt"
    @file_info = {} # map filename => { 'sync_ts' => timestamp, 'sha256' => sha256 }

    # if the info file exists, load it
    begin
      _validate_and_set_file_info(YAML.load_file(@file_info_filename)) if File.exist?(@file_info_filename)
    rescue Exception => e
      puts "💀  ERROR: could not load file info from #{@file_info_filename}"
      puts e
      exit -1
    end
  end

  def save_file_info
    dest_file = Tempfile.new('file_sync_db')
    dest_file.write(@file_info.to_yaml)
    dest_file.close()
    FileUtils.mv(dest_file.path, @file_info_filename)
  rescue Exception => e
    puts "💀  ERROR: could not save file sync db to #{@file_info_filename}"
    puts e
    exit -1
  end

  # determine a list of files to update, and update our file info accordingly so it can be saved for the next run
  def update_file_info_and_find_all_files_to_up_sync!(puts_prefix)
    # get a list of everything in this folder, and select only those that need to be sync'd
    all_file_stats = {}
    _find_all_file_stats(@folder_name, all_file_stats)

    # calculate shas for the files we need them for
    all_shas = _get_required_file_shas(puts_prefix, all_file_stats)

    # compute anything that needs to be up-sync'd
    # - if we don't have a record for it
    # - if we have a sha, but the sha record doesn't match (or isn't present)
    # - if we have a timestamp, and the timestamp is newer than the record
    sync_filenames = []
    all_file_stats.each do |filename, stats|
      req_sync = false
      file_info_line = @file_info[filename]
      sha256 = all_shas[filename]
      req_sync =
        if not file_info_line
          # we don't have a file info line yet for this file
          true
        elsif sha256
          # we have a sha256, so only update if it doesn't match what we have in our file info
          sha256 != file_info_line['sha256']
        elsif stats['modified_ts'] > file_info_line['sync_ts']
          # timestamp is newer on the actual file than in our info line, so update
          true
        else
          false
        end
      sync_filenames << filename if req_sync
    end

    # update our file info; update sync time to be now, and sha256 if we have it
    sync_ts = Time.now.to_i
    all_file_stats.each do |filename, stats|
      file_info_line = @file_info[filename]
      unless file_info_line
        @file_info[filename] = {}
        file_info_line = @file_info[filename]
      end

      # update our sha256
      # - note this will clear out shas that might have been there before
      # - this is desired; it will eliminate stale shas even if stale because we changed the limit
      file_info_line['sha256'] = all_shas[filename]

      # update our sync time
      file_info_line['sync_ts'] = sync_ts
    end

    sync_filenames
  end

  # refresh everything for files newer than the given timestamp
  # - this is intended for use after down sync, to update the file sync db with any downloaded files
  def update_file_info_after_down_sync!(puts_prefix, down_sync_ts)
    all_file_stats = {}
    _find_all_file_stats(@folder_name, all_file_stats)

    # choose only the newly downloaded or updated files
    new_file_stats = {}
    all_file_stats.each do |filename, stats|
      if stats['modified_ts'] > down_sync_ts
        new_file_stats[filename] = stats
      end
    end

    # calculate shas for new files, as needed, as with up-sync
    all_shas = _get_required_file_shas(puts_prefix, new_file_stats)

    # update file infos for all the ewer files
    new_file_stats.each do |filename, stats|
      file_info_line = @file_info[filename]
      unless file_info_line
        @file_info[filename] = {}
        file_info_line = @file_info[filename]
      end

      # set sha2456, as with up-sync
      file_info_line['sha256'] = all_shas[filename]

      # set the sync ts to the file modified ts
      file_info_line['sync_ts'] = stats['modified_ts']
    end
  end

  private

  # set the @file_info array from file_info, validating it first
  def _validate_and_set_file_info(file_info)
    # check that file_info is a hash
    unless file_info.is_a?(Hash)
      raise Exception, "loaded file info is not a hash"
    end

    # check that each element is a hash, keyed on filename in this folder, and with no unexpected fields
    valid_info_keys = [ 'sync_ts', 'sha256' ]
    file_info.each do |filename, info|
      unless filename.is_a?(String)
        raise Exception, "loaded file info contains an invalid key #{filename}"
      end
      unless filename.start_with?("#{@folder_name}/") && Pathname.new(filename).cleanpath.to_s == filename
        raise Exception, "loaded file info contains a filename #{filename} not in the expected path #{@folder_name}"
      end

      unless info.is_a?(Hash)
        raise Exception, "loaded file info contains a line that is not a hash"
      end
      invalid_info_keys = info.keys - valid_info_keys
      unless invalid_info_keys.empty?
        raise Exception, "loaded file info contains a line with one or more invalid keys: #{invalid_info_keys}"
      end
    end

    # made it this far, then everything is good
    @file_info = file_info
  end

  # find all files, starting from the given folder, not including dotfiles
  # @param dest_file_stats [Hash<String, Hash>] output map from filename => { 'size' => size, 'modified_ts' => mtime }
  def _find_all_file_stats(folder_name, dest_file_stats)
    Dir.glob("#{folder_name}/*") do |f|
      if File.basename(f).start_with?('.')
      elsif File.directory?(f)
        _find_all_file_stats(f, dest_file_stats)
      elsif File.file?(f)
        fs = File.stat(f)
        raise Exception, "could not stat file: #{f}" unless fs
        dest_file_stats[f] = {
          'size' => fs.size,
          'modified_ts' => fs.mtime.to_i
        }
      else
        print "💀  WARNING: not adding file #{f}"
      end
    end
  end

  # calculate all shas for required files, given an input file stats map
  # - if FAST_MODE is not set, or this folder is in FAST_MODE_EXCLUDE_ROOT_DIRS, then this will be all files
  # - otherwise, this will be all files smaller than FAST_MODE_FILE_SIZE_LIMIT
  def _get_required_file_shas(puts_prefix, all_file_stats)
    all_sha_filenames = []
    if !FAST_MODE || FAST_MODE_EXCLUDE_ROOT_DIRS.include?(@folder_name)
      puts "#{puts_prefix}: ! computing full sha signatures for folder #{@folder_name}"
      all_sha_filenames = all_file_stats.keys
    else
      puts "#{puts_prefix}: ! computing partial sha signatures for folder #{@folder_name}"
      all_file_stats.each do |filename, stats|
        if stats.size >= FAST_MODE_FILE_SIZE_LIMIT
          all_sha_filenames << filename
        end
      end
    end

    get_file_shas(puts_prefix, all_sha_filenames)
  end
end

# sync a folder UP, using rsync
# - this is called by sync_folder
# - will not update timefile
#
# @param folder_name [String] the folder name to sync
# @param file_sync_db [FileSyncDB] the file sync db object for this folder
# @return [Boolean] true if the folder was up-sync'd successfully, false
#   otherwise
def sync_folder_up(puts_prefix, folder_name, file_sync_db)
  # get all files nwer than the given date
  rsync_files = file_sync_db.update_file_info_and_find_all_files_to_up_sync!(puts_prefix)

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

  # make sure at least SLEEP_TIME passes between rsync, but do it in a thread
  # so we count the time spent saving the shas file as sleep time
  sleep_thread = Thread.new do
    sleep SLEEP_TIME
  end

  # save the shas file if the rsync was a success
  if rsync_status.success?
    if RSYNC_DRY_RUN.empty?
      puts "#{puts_prefix}:✅  Up-sync succeeded; saving the file info for this folder."
      file_sync_db.save_file_info
    else
      puts "#{puts_prefix}:✅  Up-sync succeeded, but operating in rsync dry-run mode; not saving the file info for this folder."
    end
  else
    puts "#{puts_prefix}:💀  WARNING: there was an rsync error while up-syncing; not saving the file info for this folder."
  end

  # sleep a short while; this is to prevent ssh thinking that's being flooded
  puts "#{puts_prefix}:🌙  sleeping #{SLEEP_TIME} seconds"
  sleep_thread.join

  # return true if the sync up worked
  rsync_status.success?
end

# sync a given folder DOWN, using rsync
#
# @param folder_name [String] the folder name to sync
# @return [Boolean] true if folder was down-sync'd, false otherwise
def sync_folder_down(puts_prefix, folder_name, file_sync_db)
  before_rsync_ts = Time.now.to_i

  rsync_upstream_folder = Shellwords.escape("#{UPSTREAM_FOLDER}/#{folder_name}")
  rsync_cmd = "rsync #{RSYNC_DRY_RUN} #{RSYNC_PROGRESS} #{RSYNC_DELETE} --update --exclude \"\\.*\" --compress --recursive --times --perms --links \"#{rsync_upstream_folder}\" ."
  puts "#{puts_prefix}: ▼ #{rsync_cmd}"
  rsync_status = Open3.popen3(ENV, rsync_cmd) do |stdin, stdout, stderr, wait_thread|
    capture_and_echo_io("#{puts_prefix}: ▼ ", stdout, stderr)
    wait_thread.join
    wait_thread.value
  end

  # refresh the file sync db with any updated files;
  # - note we do this regardless the downsync status, because we always want to be up to date here
  file_sync_db.update_file_info_after_down_sync!(puts_prefix, before_rsync_ts)
  file_sync_db.save_file_info

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

  # initialize our file info db, for syncing
  file_sync_db = FileSyncDB.new(folder_name)

  # sync them up
  rsync_up_succeeded = sync_folder_up(puts_prefix, folder_name, file_sync_db)

  # sync down, but only if there were no errors syncing up
  unless rsync_up_succeeded
    puts "#{puts_prefix}:💀  WARNING: rsync failed while up-syncing; not syncing this folder down."
  else
    rsync_down_succeeded = sync_folder_down(puts_prefix, folder_name, file_sync_db)

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
  puts "#{puts_prefix}:💀  ERROR: canceling folder due to rescued exception: #{e}: #{e.backtrace.join(', ')}"
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
