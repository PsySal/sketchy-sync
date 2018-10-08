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
    # git can't commit empty folders; add the one in test data here
    empty_sub_folder = "#{TESTING_DATA_DIR}/TESTING/empty_sub_folder"
    Dir.mkdir empty_sub_folder unless Dir.exist? empty_sub_folder

    [false, true].each do |fast_mode|
      @fast_mode = true # fast_mode
      test_dot_sync_dir_was_initialized
      test_up_sync_into_empty_dir
      test_up_sync_file_changes_locally
      test_up_sync_immediate_change_to_new_file_from_down_sync
      test_down_sync_into_empty_dir_folders
      test_down_sync_file_changes_on_server
      test_down_sync_file_changes_locally
      test_down_sync_with_and_without_enable_rsync_delete
      test_down_sync_file_deleted_locally_restored_after_down_sync
      test_down_sync_file_moved_remotely_down_sync_file_duplicated # test down sync, file moved on server, down sync, file in both places (rsync delete off)
      test_down_sync_file_moved_remotely_down_sync_file_moved_enable_rsync_delete # test rsync delete on, down sync, file moved on server, down sync, file moved locally
    end

    # test fast mode failure case (file contents changed but date not)
    # test fast mode limit
    # test fast mode exclude root folders

    puts
  end

  def test_dot_sync_dir_was_initialized
    local_dir, remote_dir = _setup(false, false, false)
    _assert_dir_contents "#{local_dir}/.sync", ['sync_settings.txt'], 'sync_settings.txt is in .sync dir'
    settings = _load_sync_settings(local_dir)
    _assert_equals settings['rsync_delete'], false, 'rsync_delete is initially set to false'
    _assert_equals settings['rsync_dry_run'], true, 'rsync_dry_run is initially set to false'
    _assert_equals settings['fast_mode'], false, 'fast_mode is initially set to false'
    _assert_equals settings['settings_are_set'], false, 'settings_are_set is initially set to false'
  end

  def test_up_sync_into_empty_dir
    local_dir, remote_dir = _setup(true, false, true)
    _assert_dir_contents remote_dir, [], 'dest dir is empty before sync'
    `./sync.rb`
    _assert_dirs_match remote_dir, local_dir, 'dest dir matches source dir after sync'
  end

  def test_up_sync_file_changes_locally
    local_dir, remote_dir = _setup(true, false, true)
    `./sync.rb`
    _assert_file_contents "#{remote_dir}/TESTING/hello.txt", "hello there\n", 'file has expected contents after initial up sync'
    _set_file_contents "#{local_dir}/TESTING/hello.txt", "hello again\n"
    `./sync.rb`
    _assert_file_contents "#{remote_dir}/TESTING/hello.txt", "hello again\n", 'file has new contents after second up sync'
  end

  def test_up_sync_immediate_change_to_new_file_from_down_sync
    local_dir, remote_dir = _setup(false, true, true)
    `mkdir #{local_dir}/TESTING`
    `./sync.rb`
    _assert_file_contents "#{local_dir}/TESTING/hello.txt", "hello there\n", 'file has expected contents after initial down sync'
    _set_file_contents "#{local_dir}/TESTING/hello.txt", "hello immediately\n"
    `./sync.rb`
    _assert_file_contents "#{remote_dir}/TESTING/hello.txt", "hello immediately\n", 'dest file has new contents after second sync'
  end

  def test_down_sync_into_empty_dir_folders
    local_dir, remote_dir = _setup(false, true, true)
    _assert_dir_contents local_dir, ['sync.rb'], 'source dir is empty before sync'
    `./sync.rb`
    _assert_dir_contents local_dir, ['sync.rb'], 'source dir is empty after down sync into empty dir'
    `mkdir #{local_dir}/TESTING`
    `mkdir #{local_dir}/TESTING_2`
    `./sync.rb`
    _assert_dirs_match local_dir, remote_dir, 'local dir matches remote dir after sync with folder created'
    _assert_dirs_match "#{local_dir}/TESTING", "#{remote_dir}/TESTING", 'local TESTING subdir matches remote after sync with folder created'
    _assert_dirs_match "#{local_dir}/TESTING_2", "#{remote_dir}/TESTING_2", 'local TESTING_2 subdir matches remote after sync with folder created'
  end

  def test_down_sync_file_changes_on_server
    local_dir, remote_dir = _setup(false, true, true)
    `mkdir #{local_dir}/TESTING`
    `./sync.rb`
    _assert_file_contents "#{local_dir}/TESTING/hello.txt", "hello there\n", 'hello.txt has expected contents after initial down sync'
    _set_file_contents "#{remote_dir}/TESTING/hello.txt", "hello again\n"
    `./sync.rb`
    _assert_file_contents "#{local_dir}/TESTING/hello.txt", "hello again\n", 'hello.txt has new contents after second down sync'
  end

  def test_down_sync_file_changes_locally
    # down sync new, update file locally, sync again, new file still new locally and on server, sync again, same
    local_dir, remote_dir = _setup(false, true, true)
    `mkdir #{local_dir}/TESTING`
    `./sync.rb`
    _assert_file_contents "#{local_dir}/TESTING/hello.txt", "hello there\n", 'hello.txt has expected contents after initial down sync'
    _set_file_contents "#{local_dir}/TESTING/hello.txt", "hello changed\n"
    `./sync.rb`
    _assert_file_contents "#{local_dir}/TESTING/hello.txt", "hello changed\n", 'hello.txt has new contents locally after second sync'
    _assert_file_contents "#{remote_dir}/TESTING/hello.txt", "hello changed\n", 'hello.txt has new contents on server after second sync'
    `./sync.rb`
    _assert_file_contents "#{local_dir}/TESTING/hello.txt", "hello changed\n", 'hello.txt has new contents locally after third sync'
    _assert_file_contents "#{remote_dir}/TESTING/hello.txt", "hello changed\n", 'hello.txt has new contents on server after third sync'
  end

  def test_down_sync_with_and_without_enable_rsync_delete
    # test down sync, file deleted on server, down sync, file not deleted, enable rsync delete, down sync, file deleted
    local_dir, remote_dir = _setup(false, true, true)
    `mkdir #{local_dir}/TESTING`
    `./sync.rb`
    _assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [ 'to_delete.txt' ], 'the file to_delete.txt is present after initial down sync'
    `rm #{remote_dir}/TESTING/sub_folder_2/to_delete.txt`
    _assert_dir_contents "#{remote_dir}/TESTING/sub_folder_2", [], 'the file to_delete.txt was deleted from the remote dir by this test'
    `./sync.rb`
    _assert_dir_contents "#{remote_dir}/TESTING/sub_folder_2", [], 'the file to_delete.txt is still absent from the remote dir, even after sync'
    _assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [ 'to_delete.txt' ], 'the file to_delete.txt is still present, even after deleting on server and second down sync'
    settings = _load_sync_settings(local_dir)
    settings['rsync_delete'] = true
    _save_sync_settings(local_dir, settings)
    `./sync.rb`
    _assert_dir_contents "#{remote_dir}/TESTING/sub_folder_2", [], 'the file to_delete.txt is still absent from the remote dir, even after a second sync'
    _assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [], 'the file to_delete.txt was deleted locally once rsync_delete was turned on'
  end

  def test_down_sync_file_deleted_locally_restored_after_down_sync
    # test down sync, file deleted local, down sync, file present again
    local_dir, remote_dir = _setup(false, true, true)
    `mkdir #{local_dir}/TESTING`
    `./sync.rb`
    _assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [ 'to_delete.txt' ], 'the file to_delete.txt is present after initial down sync'
    `rm #{local_dir}/TESTING/sub_folder_2/to_delete.txt`
    `./sync.rb`
    _assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [ 'to_delete.txt' ], 'the file to_delete.txt was restored after the second sync'
  end

  def test_down_sync_file_moved_remotely_down_sync_file_duplicated
    # test down sync, file moved on server, down sync, file in both places (rsync delete off)
    local_dir, remote_dir = _setup(false, true, true)
    `mkdir #{local_dir}/TESTING`
    `./sync.rb`
    _assert_dir_contents "#{local_dir}/TESTING/sub_folder", [ 'text 456.txt' ], 'the file test 456.txt is present in TESTING/sub_folder after initial sync'
    `mv #{remote_dir}/TESTING/sub_folder/text\\ 456.txt #{remote_dir}/TESTING/sub_folder_2`
    `./sync.rb`
    _assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [ 'text 456.txt', 'to_delete.txt' ], 'the file test 456.txt is in TESTING/sub_folder_2 after move on the remote and a second sync'
    _assert_dir_contents "#{local_dir}/TESTING/sub_folder", [ 'text 456.txt' ], 'the file test 456.txt is still present in TESTING/sub_folder after second sync (because rsync delete is disabled)'
  end

  def test_down_sync_file_moved_remotely_down_sync_file_moved_enable_rsync_delete
    # test rsync delete on, down sync, file moved on server, down sync, file moved locally
    local_dir, remote_dir = _setup(false, true, true)
    settings = _load_sync_settings(local_dir)
    settings['rsync_delete'] = true
    _save_sync_settings(local_dir, settings)
    `mkdir #{local_dir}/TESTING`
    `./sync.rb`
    _assert_dir_contents "#{local_dir}/TESTING/sub_folder", [ 'text 456.txt' ], 'the file test 456.txt is present in TESTING/sub_folder after initial sync'
    `mv #{remote_dir}/TESTING/sub_folder/text\\ 456.txt #{remote_dir}/TESTING/sub_folder_2`
    `./sync.rb`
    _assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [ 'text 456.txt', 'to_delete.txt' ], 'the file test 456.txt is in TESTING/sub_folder_2 after move on the remote and a second sync'
    _assert_dir_contents "#{local_dir}/TESTING/sub_folder", [], 'the file test 456.txt is no longer present in TESTING/sub_folder after second sync (because rsync delete is enabled)'
  end

  private

  def _setup(init_local_dir_contents, init_remote_dir_contents, init_settings = false)
    Dir.mkdir(TEMP_DIR) unless Dir.exist?(TEMP_DIR)
    local_dir = _cleanpath Dir.mktmpdir('local_', TEMP_DIR)
    remote_dir = _cleanpath Dir.mktmpdir('remote_', TEMP_DIR)

    _assert_dir_contents_size local_dir, 0, 'source dir is empty before setup'
    _setup_dir_contents local_dir, 'source dir' if init_local_dir_contents

    _assert_dir_contents_size remote_dir, 0, 'dest dir is empty before setup'
    _setup_dir_contents remote_dir, 'dest dir' if init_remote_dir_contents

    `cp #{Shellwords.escape(SYNC_RB)} #{Shellwords.escape(local_dir)}`
    Dir.chdir(local_dir)
    # _assert_equals local_dir, _cleanpath(Dir.getwd), 'changed working dir to source testing dir'
    sync_output = `./sync.rb`
    _assert_string_match sync_output, 'ERROR: please edit .sync/sync_settings.txt', 'first-run .sync dir setup'

    _setup_settings(local_dir, remote_dir) if init_settings

    return local_dir, remote_dir
  end

  def _setup_dir_contents(dir, dir_desc)
    `cp -R #{Shellwords.escape(TESTING_DATA_DIR)}/* #{Shellwords.escape(dir)}`
    _assert_dir_contents dir, ['TESTING', 'TESTING_2'], "#{dir_desc} has expected folders after setup"
    _assert_dir_contents "#{dir}/TESTING/sub_folder/", ['text 456.txt'], "#{dir_desc} has expected files in TESTING/sub_folder after setup"
    _assert_dir_contents_size "#{dir}/TESTING", 7, "#{dir_desc} has expected number of files in TESTING/ after setup"
  end

  def _setup_settings(local_dir, remote_dir)
    settings = _load_sync_settings(local_dir)
    settings['upstream_folder'] = "#{remote_dir}"
    settings['sleep_time'] = 0
    settings['rsync_dry_run'] = false
    settings['fast_mode'] = @fast_mode
    settings['fast_mode_file_size_limit_mb'] = 0
    settings['settings_are_set'] = true
    _save_sync_settings(local_dir, settings)
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

  def _sync_settings_filename(local_dir)
    "#{local_dir}/.sync/sync_settings.txt"
  end

  def _load_sync_settings(local_dir)
    YAML.load_file(_sync_settings_filename(local_dir))
  end

  def _save_sync_settings(local_dir, settings)
    File.write(_sync_settings_filename(local_dir), settings.to_yaml)
  end
end

SyncTester.new
