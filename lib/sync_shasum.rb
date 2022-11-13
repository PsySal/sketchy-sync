# Wrap the shasum binary and parse output
class SyncSHASum
	SHASUM_BIN = 'shasum -b'

	# for the given list of filenames, return a hash filename => sha
	# - this just calls shasum with these files as input, and parses the output
	def self.get_file_shas(puts_prefix, filenames)
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
			unless puts_prefix.nil?
				print "#{puts_prefix}: △ calculated shas for #{num_filenames_processed} / #{filenames.size} files\r"
			end
			shasum_cmd = "#{SHASUM_BIN} #{some_filenames_escaped.join(' ')}"
			shasum_stdout += `#{shasum_cmd}`
		end
		print "\n" unless puts_prefix.nil?

		# shasum_cmd = "#{SHASUM_BIN} #{filenames_escaped.join(' ')}"
		# shasum_stdout = `#{shasum_cmd}`
		self._load_file_shas(shasum_stdout.split("\n"))
	end

	private

	# parse file shas from a given list of text file
	# - can be used to parse the output of shasum, as well
	# @return [Hash<String, String>] mapping filename => sha256
	def self._load_file_shas(source_file)
		file_shas = {}
		source_file.each do |source_file_line|
			source_file_line.chomp!
			source_file_sha = source_file_line[0..39] # get the sha
			source_file_star = source_file_line[41..41]
			source_file_path = source_file_line[42..-1] # skip space, binary "*" prefix
			unless '*' == source_file_star && source_file_sha =~ /\A\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\h\z/
				puts "💀  ERROR: could not load shas; bad shas file or shasum binary '#{SHASUM_BIN}' does not work as expected"
				exit(-1)
			end
			file_shas[source_file_path] = source_file_sha.downcase
		end
		file_shas
	end
end