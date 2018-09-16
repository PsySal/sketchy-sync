#!/usr/bin/env ruby

require 'pathname'
require 'shellwords'
require 'tmpdir'
require 'yaml'

class SyncTester
  SYNC_RB="#{__dir__}/sync.rb"
  TESTING_DATA_DIR="#{__dir__}/test_data"

  def initialize
    test_dot_sync_dir_was_initialized
    test_up_sync
  end

  def test_dot_sync_dir_was_initialized
    source_dir, dest_dir = _setup
    _assert_dir_contents "#{source_dir}/.sync", ['sync_settings.txt'], 'sync_settings.txt is in .sync dir'
    settings = _load_sync_settings(source_dir)
    _assert_equals settings['rsync_delete'], false, 'rsync_delete is initially set to false'
    _assert_equals settings['rsync_dry_run'], true, 'rsync_dry_run is initially set to false'
    _assert_equals settings['fast_mode'], false, 'fast_mode is initially set to false'
    _assert_equals settings['settings_are_set'], false, 'settings_are_set is initially set to false'
  end

  def test_up_sync
    source_dir, dest_dir = _setup
    settings = _load_sync_settings(source_dir)
    settings['upstream_folder'] = "calvin@localhost:#{dest_dir}"
    settings['rsync_dry_run'] = false
    settings['settings_are_set'] = true
    _save_sync_settings(source_dir, settings)
    puts source_dir, dest_dir
    sync_output = `./sync.rb`
    puts sync_output
  end

  private

  def _setup
    source_dir = _cleanpath Dir.mktmpdir
    dest_dir = _cleanpath Dir.mktmpdir

    `cp -R #{Shellwords.escape(TESTING_DATA_DIR)}/* #{Shellwords.escape(source_dir)}`
    `cp #{Shellwords.escape(SYNC_RB)} #{Shellwords.escape(source_dir)}`
    _assert_dir_contents source_dir, ['sync.rb', 'TESTING', 'TESTING_2'], 'setup of source TESTING tempdir'
    _assert_dir_contents "#{source_dir}/TESTING/sub_folder/", ['text 456.txt'], 'setup of TESTING/sub_folder'
    _assert_dir_contents_size "#{source_dir}/TESTING", 6, 'number of files in source TESTING tempdir'
    _assert_dir_contents_size dest_dir, 0, 'number of files in destination tempdir'
    Dir.chdir(source_dir)
    # _assert_equals source_dir, _cleanpath(Dir.getwd), 'changed working dir to source testing dir'
    sync_output = `./sync.rb`
    _assert_string_match sync_output, 'ERROR: please edit .sync/sync_settings.txt', 'first-run .sync dir setup'

    return source_dir, dest_dir
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

  def _assert_dir_contents(dir, contents, desc)
    _assert_equals _dir_contents(dir).sort.join(','), contents.sort.join(','), desc
  end

  def _assert_dir_contents_size(dir, expected_size, desc)
    _assert_equals _dir_contents(dir).size, expected_size, desc
  end

  def _dir_contents(dir)
    `ls -1 #{Shellwords.escape(dir)}`.split("\n")
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
