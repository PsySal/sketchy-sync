#!/usr/bin/env ruby

require 'pathname'
require 'shellwords'
require 'tmpdir'

class SyncTester
  SYNC_RB="#{__dir__}/sync.rb"
  TESTING_DATA_DIR="#{__dir__}/TESTING"

  def initialize
    test_dot_sync_dir_was_initialized
  end

  def test_dot_sync_dir_was_initialized
    setup
    _assert_dir_contents
  end

  def setup
    source_test_dir = _cleanpath Dir.mktmpdir
    dest_test_dir = _cleanpath Dir.mktmpdir

    `cp -R #{Shellwords.escape(TESTING_DATA_DIR)} #{Shellwords.escape(source_test_dir)}`
    `cp #{Shellwords.escape(SYNC_RB)} #{Shellwords.escape(source_test_dir)}`
    _assert_dir_contents source_test_dir, ['sync.rb', 'TESTING'], 'setup of source TESTING tempdir'
    _assert_dir_contents_size "#{source_test_dir}/TESTING", 4, 'number of files in source TESTING tempdir'
    _assert_dir_contents_size dest_test_dir, 0, 'number of files in destination tempdir'
    Dir.chdir(source_test_dir)
    # _assert_equals source_test_dir, _cleanpath(Dir.getwd), 'changed working dir to source testing dir'
    sync_output = `./sync.rb`
    puts sync_output
  end

  private

  def _assert_equals(actual, expected, desc)
    raise "actual #{actual} != expected #{expected} (checking #{desc})" unless actual == expected
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
end

SyncTester.new
