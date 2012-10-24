# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'gaspar/version'

Gem::Specification.new do |gem|
  gem.name          = "gaspar"
  gem.version       = Gaspar::VERSION
  gem.authors       = ["Chris Heald"]
  gem.email         = ["cheald@mashable.com"]
  gem.description   = %q{Gaspar is an in-process recurring job manager. It is intended to be used in place of cron when you don't want a separate daemon.}
  gem.summary       = %q{Gaspar is an in-process recurring job manager.}
  gem.homepage      = "http://github.com/mashable/gaspar"

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]

  gem.add_dependency('rufus-scheduler')
  gem.add_dependency('redis', '>= 2.2.0')
  gem.add_dependency('colorize')
  gem.add_dependency('active_support')
  gem.add_development_dependency('rspec')
  gem.add_development_dependency('timecop')
end
