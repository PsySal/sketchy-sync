Gem::Specification.new do |s|
	s.name        = 'sketchy_sync'
	s.version     = '2.0.0'
	s.summary     = 'Sketchy Sync'
	s.description = "Sketchy tool for rsync'ing files. I really can't recommend you use this-- it's just not very safe and may even delete/overwrite files unexpectedly. O.K. you've been warned!"
	s.authors     = ['Calvin French']
	s.email       = 'calvin@kittylambda.com'
	s.files       = ['bin/sketchy-sync.rb', 'lib/sync_db.rb', 'lib/sync_settings.rb', 'lib/sync_shasum.rb', 'lib/sync_tester.rb', 'lib/syncer.rb']
	s.executables << 'sketchy-sync.rb'
	s.homepage    = 'https://rubygems.org/gems/sketchy_sync'
	s.license     = 'MIT'
end
