Gem::Specification.new do |s|
	s.name        = 'sketchy_sync'
	s.version     = '2.0.0'
	s.summary     = 'Sketchy Sync'
	s.description = "Sketchy tool for rsync'ing files. I really can't recommend you use this-- it's just not very safe and may even delete/overwrite files unexpectedly. O.K. you've been warned!"
	s.authors     = ['Calvin French']
	s.email       = 'calvin@kittylambda.com'
	s.files       = [
		'bin/sketchy-sync.rb',
		'lib/sync_db.rb', 'lib/sync_settings.rb', 'lib/sync_shasum.rb', 'lib/sync_tester.rb', 'lib/syncer.rb',
		'lib/test_data/TESTING/sub_folder/text 456.txt',
		'lib/test_data/TESTING/sub_folder_2/to_delete.txt',
		'lib/test_data/TESTING/hello.txt', 'lib/test_data/TESTING/testing 123.txt',
		'lib/test_data/TESTING/tumblr_mwvnlfau761qaz1ado1_500.jpg', 'lib/test_data/TESTING/tumblr_whtebkgrnd_or7r0eFi751rrj10do1_r1_540.gif',
		'lib/test_data/TESTING_2/nothing.txt'
	]
	s.executables << 'sketchy-sync.rb'
	s.homepage    = 'https://rubygems.org/gems/sketchy_sync'
	s.license     = 'MIT'
end
