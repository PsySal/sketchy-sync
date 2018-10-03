#!/usr/bin/env ruby

require 'pathname'
require 'shellwords'
require 'tmpdir'
require 'yaml'

class SyncTester
  SYNC_RB="#{__dir__}/sync.rb"
  TESTING_DATA_DIR="#{__dir__}/test_data"
  TEMP_DIR="#{__dir__}/temp"

  def initialize
    #test_dot_sync_dir_was_initialized
    #test_up_sync_into_empty_dir
    test_up_sync_file_changes_locally
    #test_down_sync_into_empty_dir_folders
    #test_down_sync_file_changes_on_server
    # test down sync, file deleted on server, down sync, file not deleted, enable rsync delete, down sync, file deleted
    # test down sync, file deleted locall, down sync, file present again
    # test above in fast and full modes
  end

  def test_dot_sync_dir_was_initialized
    source_dir, dest_dir = _setup(false, false)
    _assert_dir_contents "#{source_dir}/.sync", ['sync_settings.txt'], 'sync_settings.txt is in .sync dir'
    settings = _load_sync_settings(source_dir)
    _assert_equals settings['rsync_delete'], false, 'rsync_delete is initially set to false'
    _assert_equals settings['rsync_dry_run'], true, 'rsync_dry_run is initially set to false'
    _assert_equals settings['fast_mode'], false, 'fast_mode is initially set to false'
    _assert_equals settings['settings_are_set'], false, 'settings_are_set is initially set to false'
  end

  def test_up_sync_into_empty_dir
    source_dir, dest_dir = _setup(true, false)
    _setup_settings(source_dir, dest_dir)
    _assert_dir_contents dest_dir, [], 'dest dir is empty before sync'
    `./sync.rb`
    _assert_dirs_match dest_dir, source_dir, 'dest dir matches source dir after sync'
  end

  def test_up_sync_file_changes_locally
    source_dir, dest_dir = _setup(true, true)
    _setup_settings(source_dir, dest_dir)
    `./sync.rb`
    _assert_file_contents "#{dest_dir}/TESTING/hello.txt", "hello there\n", 'file has expected contents after initial up sync'
    _set_file_contents "#{source_dir}/TESTING/hello.txt", "hello again\n"
    `./sync.rb`
    _assert_file_contents "#{dest_dir}/TESTING/hello.txt", "hello again\n", 'file has new contents after second up sync'
  end

  def test_down_sync_into_empty_dir_folders
    source_dir, dest_dir = _setup(false, true)
    _setup_settings(source_dir, dest_dir)
    _assert_dir_contents source_dir, ['sync.rb'], 'source dir is empty before sync'
    `./sync.rb`
    _assert_dir_contents source_dir, ['sync.rb'], 'source dir is empty after down sync into empty dir'
    `mkdir #{source_dir}/TESTING`
    `mkdir #{source_dir}/TESTING_2`
    `./sync.rb`
    _assert_dirs_match source_dir, dest_dir, 'source dir matches dest dir after sync with folder created'
  end

  def test_down_sync_file_changes_on_server
    source_dir, dest_dir = _setup(false, true)
    _setup_settings(source_dir, dest_dir)
    `mkdir #{source_dir}/TESTING`
    `./sync.rb`
    _assert_file_contents "#{dest_dir}/TESTING/hello.txt", "hello there\n", 'hello.txt has expected contents after initial down sync'
    _set_file_contents "#{source_dir}/TESTING/hello.txt", "hello again\n"
    `./sync.rb`
    _assert_file_contents "#{dest_dir}/TESTING/hello.txt", "hello again\n", 'hello.txt has new contents after second down sync'
  end

  private

  def _setup(init_source_dir_contents, init_dest_dir_contents)
    Dir.mkdir(TEMP_DIR) unless Dir.exist?(TEMP_DIR)
    source_dir = _cleanpath Dir.mktmpdir('source_', TEMP_DIR)
    dest_dir = _cleanpath Dir.mktmpdir('dest_', TEMP_DIR)

    _assert_dir_contents_size source_dir, 0, 'source dir is empty before setup'
    _setup_dir_contents source_dir, 'source dir' if init_source_dir_contents

    _assert_dir_contents_size dest_dir, 0, 'dest dir is empty before setup'
    _setup_dir_contents dest_dir, 'dest dir' if init_dest_dir_contents

    `cp #{Shellwords.escape(SYNC_RB)} #{Shellwords.escape(source_dir)}`
    Dir.chdir(source_dir)
    # _assert_equals source_dir, _cleanpath(Dir.getwd), 'changed working dir to source testing dir'
    sync_output = `./sync.rb`
    _assert_string_match sync_output, 'ERROR: please edit .sync/sync_settings.txt', 'first-run .sync dir setup'

    return source_dir, dest_dir
  end

  def _setup_dir_contents(dir, dir_desc)
    `cp -R #{Shellwords.escape(TESTING_DATA_DIR)}/* #{Shellwords.escape(dir)}`
    _assert_dir_contents dir, ['TESTING', 'TESTING_2'], "#{dir_desc} has expected folders after setup"
    _assert_dir_contents "#{dir}/TESTING/sub_folder/", ['text 456.txt'], "#{dir_desc} has expected files in TESTING/sub_folder after setup"
    _assert_dir_contents_size "#{dir}/TESTING", 6, "#{dir_desc} has expected number of files in TESTING/ after setup"
  end

  def _setup_settings(source_dir, dest_dir)
    settings = _load_sync_settings(source_dir)
    settings['upstream_folder'] = "#{dest_dir}"
    settings['sleep_time'] = 0
    settings['rsync_dry_run'] = false
    settings['settings_are_set'] = true
    _save_sync_settings(source_dir, settings)
  end

  def _assert_equals(actual, expected, desc)
    raise "actual #{actual} != expected #{expected} (checking #{desc})" unless actual == expected
    printf '.'
    STDOUT.sync
  end

  def _assert_string_match(string, pattern, desc)
    raise "string #{string} does not contain pattern #{pattern} (checking #{desc})" unless string.match(pattern)
    printf '.'
    STDOUT.sync
  end

  def _assert_dirs_match(actual_dir, expected_dir, desc)
    actual_dir_contents = _dir_contents_recursive(actual_dir).sort.join(',')
    expected_dir_contents = _dir_contents_recursive(expected_dir).sort.join(',')
    _assert_equals actual_dir_contents, expected_dir_contents, desc
  end

  def _assert_dir_contents(dir, contents, desc)
    _assert_equals _dir_contents(dir).sort.join(','), contents.sort.join(','), desc
  end

  def _assert_dir_contents_size(dir, expected_size, desc)
    _assert_equals _dir_contents(dir).size, expected_size, desc
  end

  def _dir_contents(dir)
    `ls -1 #{Shellwords.escape(dir)}`.split("\n")
  end

  def _dir_contents_recursive(dir)
    prev_cwd = Dir.pwd
    Dir.chdir(dir)
    contents = `find . -not -type d -and -not -path "\./sync\.rb" -and -not -path "\./\.sync/*"`.split("\n")
    Dir.chdir(prev_cwd)
    contents
  end

  def _assert_file_contents(filename, contents, desc)
    _assert_equals _file_contents(filename), contents, desc
  end

  def _set_file_contents(filename, contents)
    File.open(filename, 'w') do |file|
      file.write(contents)
    end
  end

  def _file_contents(filename)
    `cat #{Shellwords.escape(filename)}`
  end

  def _cleanpath(dir)
    File.expand_path(dir, '/')
  end

  def _sync_settings_filename(source_dir)
    "#{source_dir}/.sync/sync_settings.txt"
  end

  def _load_sync_settings(source_dir)
    YAML.load_file(_sync_settings_filename(source_dir))
  end

  def _save_sync_settings(source_dir, settings)
    File.write(_sync_settings_filename(source_dir), settings.to_yaml)
  end
end

SyncTester.new
