#!/usr/bin/env ruby

require 'net/ssh'
require 'pathname'
require 'securerandom'
require 'shellwords'
require 'tmpdir'
require 'yaml'

class SyncTesterRetryError < Exception; end
class SyncTesterFailedAssertionError < Exception; end

class SyncTester
	SYNC_RB="#{__dir__}/sync.rb"
	TESTING_DATA_DIR="#{__dir__}/test_data"
	TEMP_DIR="#{__dir__}/temp"
	REMOTE_TEMP_DIR="calvin@musicbox:/Users/calvin/Temp"
	MAX_RETRIES_PER_TEST = 5
	RETRY_DELAY_S = 5
	SYNC_REMOTE_SLEEP_DELAY_S = 0 # can be 0; set to higher numbers to reduce the number of retries due to remote host ssh throttling
	SET_FILE_CONTENTS_FAST_MODE_SLEEP_DELAY_S = 1 # should be at least 1; this is a limitation of using mtime, atime, and rsync
	DEBUG_VERBOSE = false # set to true for verbose output from tests

	def initialize
		# git can't commit empty folders; add the one in test data here
		empty_sub_folder = "#{TESTING_DATA_DIR}/TESTING/empty_sub_folder"
		_mkdir empty_sub_folder unless _dir_exist?(empty_sub_folder)

		# ssh session management; we'll map remote_host (String) to an ssh session, and allocate as needed in _exec_remote
		@remote_ssh_sessions = {}

		# collect failed and retried tests to report after
		@failed_tests = []
		@retried_tests = []

		# run all methods starting with test_
		test_methods = methods.select { |method_sym| method_sym.to_s.start_with? 'test_' }
		test_methods.shuffle!
		[false, true].each do |use_remote_temp_dir|
			@use_remote_temp_dir = use_remote_temp_dir
			[false, true].each do |fast_mode|
				@fast_mode = fast_mode
				test_methods.each do |test_method|
					_run_test test_method
				end
			end

			# test include/exclude root folders, all modes
			# test fast mode failure case (file contents changed but date not)
			# test fast mode limit
			# test fast mode exclude root folders
			# test fast mode - add a new folder locally with an old mtime that doesn't exist on server, make sure it updates
		end

		puts
		(['retried tests:'] + @retried_tests).each { |s| puts s } unless @retried_tests.empty?
		(['failed tests:'] + @failed_tests).each { |s| puts s } unless @failed_tests.empty?
	end

	# test shasum to make sure it works as expected
	def test_shasum
		sync_temp_file = Tempfile.new('sync temp')
		sync_temp_file.write('sync')
		sync_temp_file_path = sync_temp_file.path
		sync_temp_file_shas = get_file_shas(nil, [sync_temp_file_path])
		unless 'da39a3ee5e6b4b0d3255bfef95601890afd80709' == sync_temp_file_shas[sync_temp_file_path]
			puts "💀  ERROR: shasum binary '#{SHASUM_BIN}' does not work as expected; cannot proceed"
			exit -1
		end
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

	def test_up_sync_pass_path_on_cmdline
		# test pass a path on the commandline, with a slash, make sure it syncs up, others don't
		local_dir, remote_dir = _setup(true, false, true)
		_sync('TESTING')
		_assert_dirs_match "#{remote_dir}/TESTING", "#{local_dir}/TESTING", 'remote TESTING dir is present after it was passed on cmdline to up sync'
		_assert_dir_contents remote_dir, [ 'TESTING' ], 'remote dir only contains TESTING (not TESTING_2) after it was passed on cmdline to up sync'
		_sync('TESTING_2/')
		_assert_dirs_match "#{remote_dir}/TESTING_2", "#{local_dir}/TESTING_2", 'remote TESTING_2 dir is present after it was passed on cmdline to up sync'
	end

	def test_up_sync_into_empty_dir
		local_dir, remote_dir = _setup(true, false, true)
		_assert_dir_contents remote_dir, [], 'dest dir is empty before sync'
		_sync
		_assert_dirs_match remote_dir, local_dir, 'dest dir matches source dir after sync'
	end

	def test_up_sync_file_changes_locally
		local_dir, remote_dir = _setup(true, false, true)
		_sync
		_assert_file_contents "#{remote_dir}/TESTING/hello.txt", "hello there\n", 'file has expected contents after initial up sync'
		_set_file_contents "#{local_dir}/TESTING/hello.txt", "hello again"
		_sync
		_assert_file_contents "#{remote_dir}/TESTING/hello.txt", "hello again", 'file has new contents after second up sync'
	end

	def test_up_sync_failed_retry_succeeded
		# test failed sync (bad remote host) (so db not updated), try again, check sync went through
		local_dir, remote_dir = _setup(true, false, true)
		settings = _load_sync_settings(local_dir)
		settings['upstream_folder'] = "user@example.com/temp"
		_save_sync_settings(local_dir, settings)
		_sync
		_assert_dir_contents remote_dir, [], 'dest dir is empty after (failed) sync'
		settings = _load_sync_settings(local_dir)
		settings['upstream_folder'] = remote_dir
		_save_sync_settings(local_dir, settings)
		_sync
		_assert_dirs_match local_dir, remote_dir, "local and remote dirs match after (successful) sync"
	end

	def test_up_sync_file_changed_locally_failed_retry_succeeded
		# test initial up sync, file changed locally, failed sync (bad remote host) (so db not updated), try again, check sync went through
		local_dir, remote_dir = _setup(true, false, true)
		_sync
		_assert_file_contents "#{remote_dir}/TESTING/hello.txt", "hello there\n", 'file has expected contents after initial upsync'
		settings = _load_sync_settings(local_dir)
		settings['upstream_folder'] = "user@example.com/temp"
		_save_sync_settings(local_dir, settings)
		_set_file_contents "#{local_dir}/TESTING/hello.txt", "this file will take two syncs to upload"
		_sync
		_assert_file_contents "#{remote_dir}/TESTING/hello.txt", "hello there\n", 'remote file is unchanged after failed sync'
		settings = _load_sync_settings(local_dir)
		settings['upstream_folder'] = remote_dir
		_save_sync_settings(local_dir, settings)
		_sync
		_assert_file_contents "#{remote_dir}/TESTING/hello.txt", "this file will take two syncs to upload", 'remote file is unchanged after failed sync'
	end

	def test_up_sync_immediate_change_to_new_file_from_down_sync
		local_dir, remote_dir = _setup(false, true, true)
		_mkdir "#{local_dir}/TESTING"
		_sync
		_assert_file_contents "#{local_dir}/TESTING/hello.txt", "hello there\n", 'file has expected contents after initial down sync'
		_set_file_contents "#{local_dir}/TESTING/hello.txt", "hello immediately"
		_sync
		_assert_file_contents "#{remote_dir}/TESTING/hello.txt", "hello immediately", 'dest file has new contents after second sync'
	end

	def test_up_sync_add_file_locally_with_old_mtime
		local_dir, remote_dir = _setup(true, false, true)
		_sync
		_assert_dirs_match "#{local_dir}/TESTING", "#{remote_dir}/TESTING", 'local TESTING dir is present and matches remote after initial down-sync'
		_mkdir "#{local_dir}/TESTING_OLD"
		one_hour_ago = Time.now - 30 * 24 * 60 * 60
		File.utime(one_hour_ago, one_hour_ago, "#{local_dir}/TESTING_OLD")
		_assert_equals one_hour_ago.to_i, File.mtime("#{local_dir}/TESTING_OLD").to_i, 'parent folder TESTING_OLD mtime was updated to an hour ago by File.utime as expected'
		_set_file_contents "#{local_dir}/TESTING_OLD/old.txt", 'a file with an old mtime'
		File.utime(one_hour_ago, one_hour_ago, "#{local_dir}/TESTING_OLD/old.txt")
		_assert_equals one_hour_ago.to_i, File.mtime("#{local_dir}/TESTING_OLD/old.txt").to_i, 'old.txt mtime was updated to an hour ago by File.utime as expected'
		_sync
		_assert_dirs_match "#{local_dir}/TESTING_OLD", "#{remote_dir}/TESTING_OLD", 'local TESTING_OLD matches remote after second sync'
		_assert_file_contents "#{remote_dir}/TESTING_OLD/old.txt", 'a file with an old mtime', 'remote old.txt file has expected contents after second sync'
	end

	def test_down_sync_pass_path_on_cmdline
		# test pass a path on the commandline, with a slash, make sure it syncs up, others don't
		local_dir, remote_dir = _setup(false, true, true)
		_sync('TESTING')
		_assert_dirs_match "#{local_dir}/TESTING", "#{remote_dir}/TESTING", 'local TESTING dir is present on remote after it was passed on cmdline to up sync'
		_assert_dir_contents local_dir, [ 'TESTING', 'sync.rb' ], 'local dir only contains TESTING (not TESTING_2) after it was passed on cmdline to up sync'
		_sync('TESTING_2/')
		_assert_dirs_match "#{local_dir}/TESTING_2", "#{remote_dir}/TESTING_2", 'local TESTING_2 dir is present after it was passed on cmdline to up sync'
	end

	def test_down_sync_into_empty_dir_folders
		local_dir, remote_dir = _setup(false, true, true)
		_assert_dir_contents local_dir, ['sync.rb'], 'source dir is empty before sync'
		_sync
		_assert_dir_contents local_dir, ['sync.rb'], 'source dir is empty after down sync into empty dir'
		_mkdir "#{local_dir}/TESTING"
		_mkdir "#{local_dir}/TESTING_2"
		_sync
		_assert_dirs_match local_dir, remote_dir, 'local dir matches remote dir after sync with folder created'
		_assert_dirs_match "#{local_dir}/TESTING", "#{remote_dir}/TESTING", 'local TESTING subdir matches remote after sync with folder created'
		_assert_dirs_match "#{local_dir}/TESTING_2", "#{remote_dir}/TESTING_2", 'local TESTING_2 subdir matches remote after sync with folder created'
	end

	def test_down_sync_file_changes_on_server
		local_dir, remote_dir = _setup(false, true, true)
		_mkdir "#{local_dir}/TESTING"
		_sync
		_assert_file_contents "#{local_dir}/TESTING/hello.txt", "hello there\n", 'hello.txt has expected contents after initial down sync'
		_set_file_contents "#{remote_dir}/TESTING/hello.txt", "hello again"
		_sync
		_assert_file_contents "#{local_dir}/TESTING/hello.txt", "hello again", 'hello.txt has new contents after second down sync'
	end

	def test_down_sync_file_changes_locally
		# down sync new, update file locally, sync again, new file still new locally and on server, sync again, same
		local_dir, remote_dir = _setup(false, true, true)
		_mkdir "#{local_dir}/TESTING"
		_sync
		_assert_file_contents "#{local_dir}/TESTING/hello.txt", "hello there\n", 'hello.txt has expected contents after initial down sync'
		_set_file_contents "#{local_dir}/TESTING/hello.txt", "hello changed"
		_sync
		_assert_file_contents "#{local_dir}/TESTING/hello.txt", "hello changed", 'hello.txt has new contents locally after second sync'
		_assert_file_contents "#{remote_dir}/TESTING/hello.txt", "hello changed", 'hello.txt has new contents on server after second sync'
		_sync
		_assert_file_contents "#{local_dir}/TESTING/hello.txt", "hello changed", 'hello.txt has new contents locally after third sync'
		_assert_file_contents "#{remote_dir}/TESTING/hello.txt", "hello changed", 'hello.txt has new contents on server after third sync'
	end

	def test_down_sync_with_and_without_enable_rsync_delete
		# test down sync, file deleted on server, down sync, file not deleted, enable rsync delete, down sync, file deleted
		local_dir, remote_dir = _setup(false, true, true)
		_mkdir "#{local_dir}/TESTING"
		_sync
		_assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [ 'to_delete.txt' ], 'the file to_delete.txt is present after initial down sync'
		_rm "#{remote_dir}/TESTING/sub_folder_2/to_delete.txt"
		_assert_dir_contents "#{remote_dir}/TESTING/sub_folder_2", [], 'the file to_delete.txt was deleted from the remote dir by this test'
		_sync
		_assert_dir_contents "#{remote_dir}/TESTING/sub_folder_2", [], 'the file to_delete.txt is still absent from the remote dir, even after sync'
		_assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [ 'to_delete.txt' ], 'the file to_delete.txt is still present, even after deleting on server and second down sync'
		settings = _load_sync_settings(local_dir)
		settings['rsync_delete'] = true
		_save_sync_settings(local_dir, settings)
		_sync
		_assert_dir_contents "#{remote_dir}/TESTING/sub_folder_2", [], 'the file to_delete.txt is still absent from the remote dir, even after a second sync'
		_assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [], 'the file to_delete.txt was deleted locally once rsync_delete was turned on'
	end

	def test_down_sync_file_deleted_locally_restored_after_down_sync
		# test down sync, file deleted local, down sync, file present again
		local_dir, remote_dir = _setup(false, true, true)
		_mkdir "#{local_dir}/TESTING"
		_sync
		_assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [ 'to_delete.txt' ], 'the file to_delete.txt is present after initial down sync'
		_rm "#{local_dir}/TESTING/sub_folder_2/to_delete.txt"
		_sync
		_assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [ 'to_delete.txt' ], 'the file to_delete.txt was restored after the second sync'
	end

	def test_down_sync_file_moved_remotely_down_sync_file_duplicated
		# test down sync, file moved on server, down sync, file in both places (rsync delete off)
		local_dir, remote_dir = _setup(false, true, true)
		_mkdir "#{local_dir}/TESTING"
		_sync
		_assert_dir_contents "#{local_dir}/TESTING/sub_folder", [ 'text 456.txt' ], 'the file test 456.txt is present in TESTING/sub_folder after initial sync'
		_mv "#{remote_dir}/TESTING/sub_folder/text 456.txt", "#{remote_dir}/TESTING/sub_folder_2"
		_sync
		_assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [ 'text 456.txt', 'to_delete.txt' ], 'the file test 456.txt is in TESTING/sub_folder_2 after move on the remote and a second sync'
		_assert_dir_contents "#{local_dir}/TESTING/sub_folder", [ 'text 456.txt' ], 'the file test 456.txt is still present in TESTING/sub_folder after second sync (because rsync delete is disabled)'
	end

	def test_down_sync_file_moved_remotely_down_sync_file_moved_enable_rsync_delete
		# test rsync delete on, down sync, file moved on server, down sync, file moved locally
		local_dir, remote_dir = _setup(false, true, true)
		settings = _load_sync_settings(local_dir)
		settings['rsync_delete'] = true
		_save_sync_settings(local_dir, settings)
		_mkdir "#{local_dir}/TESTING"
		_sync
		_assert_dir_contents "#{local_dir}/TESTING/sub_folder", [ 'text 456.txt' ], 'the file test 456.txt is present in TESTING/sub_folder after initial sync'
		_mv "#{remote_dir}/TESTING/sub_folder/text 456.txt", "#{remote_dir}/TESTING/sub_folder_2"
		_sync
		_assert_dir_contents "#{local_dir}/TESTING/sub_folder_2", [ 'text 456.txt', 'to_delete.txt' ], 'the file test 456.txt is in TESTING/sub_folder_2 after move on the remote and a second sync'
		_assert_dir_contents "#{local_dir}/TESTING/sub_folder", [], 'the file test 456.txt is no longer present in TESTING/sub_folder after second sync (because rsync delete is enabled)'
	end

	private

	def _run_test(test_method)
		retry_counter = MAX_RETRIES_PER_TEST
		loop do
			begin
				self.send test_method
				break
			rescue SyncTesterFailedAssertionError => e
				@failed_tests << "#{test_method} (#{e})"
				_dot 'F'
				break
			rescue SyncTesterRetryError => e
				retry_counter -= 1
				raise "ran out of test retries in #{test_method} (#{e})" if 0 == retry_counter
				sleep RETRY_DELAY_S
				@retried_tests << "#{test_method} (#{e})"
				_dot 'r'
			end
		end
	end

	def _setup(init_local_dir_contents, init_remote_dir_contents, init_settings = false)
		_mkdir TEMP_DIR unless _dir_exist?(TEMP_DIR)
		_mkdir REMOTE_TEMP_DIR unless REMOTE_TEMP_DIR.nil? || _dir_exist?(REMOTE_TEMP_DIR)

		temp_dir_suffix = "#{Time.now.strftime("%Y-%m-%d")}_#{SecureRandom.hex(4)}"
		local_dir = "#{TEMP_DIR}/local_#{temp_dir_suffix}"
		raise "local temp dir #{local_dir} already exists" if _dir_exist?(local_dir)
		_mkdir local_dir

		remote_dir_prefix = @use_remote_temp_dir ? REMOTE_TEMP_DIR : TEMP_DIR
		remote_dir = "#{remote_dir_prefix}/remote_#{temp_dir_suffix}"
		raise "remote dir #{remote_dir} already exists" if _dir_exist? remote_dir
		_mkdir remote_dir
		_assert_dir_contents_size local_dir, 0, 'source dir is empty before setup'
		_setup_dir_contents local_dir, 'source dir' if init_local_dir_contents

		_assert_dir_contents_size remote_dir, 0, 'dest dir is empty before setup'
		_setup_dir_contents remote_dir, 'dest dir' if init_remote_dir_contents

#    `cp #{Shellwords.escape(SYNC_RB)} #{Shellwords.escape(local_dir)}`
		_exec_local("cp -R #{Shellwords.escape(SYNC_RB)} #{Shellwords.escape(local_dir)}")
		Dir.chdir(local_dir)
		sync_output = _sync
		_assert_string_match sync_output, 'ERROR: please edit .sync/sync_settings.txt', 'first-run .sync dir setup'

		_setup_settings(local_dir, remote_dir) if init_settings

		return local_dir, remote_dir
	end

	def _setup_dir_contents(dir, dir_desc)
		remote_host, remote_dir = _remote_host_and_path dir
		if remote_host
			_exec_local("scp -r #{Shellwords.escape(TESTING_DATA_DIR)}/* #{Shellwords.escape(remote_host)}:#{Shellwords.escape(remote_dir)}")
		else
			_exec_local("cp -R #{Shellwords.escape(TESTING_DATA_DIR)}/* #{Shellwords.escape(dir)}")
		end
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
		settings['settings_are_set'] = true
		_save_sync_settings(local_dir, settings)
	end

	def _assert_desc(desc = nil)
		checking_desc = desc ? "(checking #{desc}) " : ''
		state_desc = "(use_remote_temp_dir=#{@use_remote_temp_dir} fast_mode=#{@fast_mode})"
		checking_desc + state_desc
	end

	def _assert_equals(actual, expected, desc)
		raise SyncTesterFailedAssertionError, "actual #{actual} != expected #{expected} #{_assert_desc(desc)}" unless actual == expected
		_dot '.'
	end

	def _assert_string_match(string, pattern, desc)
		raise SyncTesterFailedAssertionError, "string #{string} does not contain pattern #{pattern} #{_assert_desc(desc)}" unless string.match(pattern)
		_dot '.'
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

	def _mkdir(dir)
		remote_host, dir = _remote_host_and_path dir
		_exec_auto_local_or_remote(remote_host, "mkdir #{Shellwords.escape(dir)}")
	end

	def _dir_exist?(dir)
		remote_host, dir = _remote_host_and_path dir
		dir == _exec_auto_local_or_remote(remote_host, "find #{Shellwords.escape(dir)} -type d -maxdepth 0").chomp
	end

	def _dir_contents(dir)
		remote_host, dir = _remote_host_and_path dir
		_exec_auto_local_or_remote(remote_host, "ls -1 #{Shellwords.escape(dir)}").split("\n")
	end

	def _dir_contents_recursive(dir)
		remote_host, dir = _remote_host_and_path dir
		_exec_auto_local_or_remote(remote_host, "cd #{Shellwords.escape(dir)} && find . -not -type d -and -not -path \"\./sync\.rb\" -and -not -path \"\./\.sync/*\"").split("\n")
	end

	def _assert_file_contents(filename, contents, desc)
		_assert_equals _file_contents(filename), contents, desc
	end

	def _file_contents(filename)
		remote_host, filename = _remote_host_and_path filename
		_exec_auto_local_or_remote(remote_host, "cat #{Shellwords.escape(filename)}")
	end

	def _set_file_contents(filename, contents)
		sleep SET_FILE_CONTENTS_FAST_MODE_SLEEP_DELAY_S if @fast_mode # XXX limitation of our scheme is we can't detect files changed within a second of syncing; make sure we don't hit that in tests
		remote_host, filename = _remote_host_and_path filename
		_exec_auto_local_or_remote(remote_host, "printf '%s' #{Shellwords.escape(contents)} >#{Shellwords.escape(filename)}")
		sleep SET_FILE_CONTENTS_FAST_MODE_SLEEP_DELAY_S if @fast_mode # XXX we need to guard this change from a sync before OR after
	end

	def _rm(filename)
		remote_host, filename = _remote_host_and_path filename
		_exec_auto_local_or_remote(remote_host, "rm #{Shellwords.escape(filename)}")
	end

	def _mv(source_filename, dest_filename_or_path)
		source_remote_host, source_filename = _remote_host_and_path source_filename
		dest_remote_host, dest_filename_or_path = _remote_host_and_path dest_filename_or_path
		raise "internal: _mv doesn't work across hosts (source #{source_remote_host} != dest #{dest_remote_host})" unless source_remote_host == dest_remote_host
		_exec_auto_local_or_remote(source_remote_host, "mv #{Shellwords.escape(source_filename)} #{Shellwords.escape(dest_filename_or_path)}")
	end

	def _remote_host_and_path(dir_or_filename)
		match_data = dir_or_filename.match /\A(?<remote_host>\p{Alnum}+@\p{Alnum}+):(?<remote_path>.*)\z/
		return false, dir_or_filename unless match_data
		return match_data[:remote_host], match_data[:remote_path]
	end

	def _net_ssh_session_for_remote_host(remote_host)
		parts = remote_host.split '@'
		raise "internal: invalid remote host format #{remote_host}" unless 2 == parts.size
		host = parts[1]
		user = parts[0]
		Net::SSH.start(host, user)
	end

	def _exec_remote(remote_host, remote_cmd)
		session = @remote_ssh_sessions[remote_host]
		if session.nil? || session.closed?
			@remote_ssh_sessions[remote_host] = _net_ssh_session_for_remote_host(remote_host)
			session = @remote_ssh_sessions[remote_host]
		end
		raise "internal: could not find or create ssh session for #{remote_host}" unless session

		puts "ssh (#{remote_host}): #{remote_cmd} 2>/dev/null" if _trace_cmd?
		session.exec!(remote_cmd)
	end

	def _exec_local(cmd)
		puts "#{cmd} 2>/dev/null" if _trace_cmd?
		`#{cmd} 2>/dev/null`
	end

	def _exec_auto_local_or_remote(remote_host, cmd)
		remote_host ? _exec_remote(remote_host, cmd) : _exec_local(cmd)
	end

	def _sync(raw_args = '')
		sleep SYNC_REMOTE_SLEEP_DELAY_S if @use_remote_temp_dir
		s = `./sync.rb #{raw_args}`
		puts s if _trace_cmd?

		if s.match? 'Connection refused'
			raise SyncTesterRetryError, "internal: sync encountered connection refused; re-running current test #{_assert_desc}"
		end

		# as long as this wasn't the first run to create skeletal sync_settings.txt, make sure fast mode affected calculated shas as expected
		unless s.empty? || s.match?('please edit .sync/sync_settings.txt')
			skipped_shas = s.match? 'skipping sha calculations'
			calculated_shas = s.match? 'computing full sha signatures'
			if @fast_mode
				_assert_equals true, skipped_shas, 'sha calculations should be skipped because fast mode is enabled'
				_assert_equals false, calculated_shas, 'full sha signatures should not be calculated because fast mode is enabled'
			else
				_assert_equals false, skipped_shas, 'sha calculations should not be skipped because fast mode is not enabled'
				_assert_equals true, calculated_shas, 'full sha signatures should be calculated because fast mode is not enabled'
			end
		end

		s
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

	def _dot(dot)
		printf(dot) && STDOUT.sync if _trace_dots?
	end

	def _trace_cmd?
		DEBUG_VERBOSE
	end

	def _trace_dots?
		!_trace_cmd?
	end
end

SyncTester.new
