Gem::Specification.new do |s|
	s.name        = "calvin_sync"
	s.version     = "1.0.0"
	s.summary     = "Calvin's Sync"
	s.description = "Sketchy tool for rsync'ing files. I really can't recommend you use this-- it's just not very safe and may even delete/overwrite files unexpectedly. O.K. you've been warned!"
	s.authors     = ["Calvin French"]
	s.email       = "calvin@kittylambda.com"
	s.files       = ["bin/calvin_sync.rb", "bin/calvin_sync_test.rb"]
	s.executables << "calvin_sync.rb"
	s.homepage    = "https://rubygems.org/gems/calvin_sync"
	s.license     = "MIT"
end
