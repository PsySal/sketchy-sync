# helper class; this represents a file information database, for storing shas and/or file sizes for a single root folder
class FileSyncDB
	def initialize(folder_name)
		@folder_name = folder_name
		@file_info_filename = "#{DOT_SYNC_FOLDER}/#{folder_name}_info.yaml"
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
	def update_file_info_and_find_all_files_to_up_sync!(puts_prefix, start_sync_ts)
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
				elsif stats['mtime'] > file_info_line['sync_ts']
					# timestamp is strictly newer on the actual file than in our info line, so update
					true
				else
					false
				end
			sync_filenames << filename if req_sync
		end

		# update our file info; update sync time to be now, and sha256 if we have it
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
			file_info_line['sync_ts'] = start_sync_ts
		end

		sync_filenames
	end

	# refresh everything for files newer than the given timestamp
	# - this is intended for use after down sync, to update the file sync db with any downloaded files
	def update_file_info_after_down_sync!(puts_prefix, start_sync_ts, end_sync_ts)
		all_file_stats = {}
		_find_all_file_stats(@folder_name, all_file_stats)

		# choose only the newly downloaded or updated files
		# - note we use rsync --times, which will preserve mtime; so, check atime instead which is the actual time the file was created
		# - we could also scan rsync output itself
		new_file_stats = {}
		all_file_stats.each do |filename, stats|
			if stats['atime'] >= start_sync_ts
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

			# set the sync ts to the file update ts; set the update ts, not the sync ts, as update will be slightly later
			file_info_line['sync_ts'] = end_sync_ts # stats['update_ts']
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
	# @param dest_file_stats [Hash<String, Hash>] output map from filename => { 'size' => size, 'mtime' => mtime, 'atime' => atime }
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
					'mtime' => fs.mtime.to_i,
					'atime' => fs.atime.to_i,
				}
			else
				print "💀  WARNING: not adding file #{f}"
			end
		end
	end

	# calculate all shas for required files, given an input file stats map
	# - this depends on the include/exclude root folders
	def _get_required_file_shas(puts_prefix, all_file_stats)
		is_root_folder_included = FAST_MODE_INCLUDE_ROOT_FOLDERS.empty? || FAST_MODE_INCLUDE_ROOT_FOLDERS.include?(@folder_name)
		is_root_folder_excluded = FAST_MODE_EXCLUDE_ROOT_FOLDERS.include?(@folder_name)
		use_fast_mode = FAST_MODE && is_root_folder_included && !is_root_folder_excluded
		all_sha_filenames =
			if use_fast_mode
				puts "#{puts_prefix}: ! skipping sha calculations for folder #{@folder_name}"
				[]
			else
				puts "#{puts_prefix}: ! computing full sha signatures for folder #{@folder_name}"
				all_file_stats.keys
			end

		get_file_shas(puts_prefix, all_sha_filenames)
	end
end
