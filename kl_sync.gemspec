Gem::Specification.new do |s|
	s.name        = "kl_sync"
	s.version     = "1.0.0"
	s.summary     = "Kitty Lambda Sync"
	s.description = "Sketchy tool for rsync'ing files. I really can't recommend you use this-- it's just not very safe and may even delete/overwrite files unexpectedly. O.K. you've been warned!"
	s.authors     = ["Calvin French"]
	s.email       = "calvin@kittylambda.com"
	s.files       = ["bin/kl-sync.rb", "lib/sync_db.rb", "lib/sync_settings.rb", "lib/sync_tester.rb", "lib/syncer.rb"]
	s.executables << "kl-sync.rb"
	s.homepage    = "https://rubygems.org/gems/kl_sync"
	s.license     = "MIT"
end
