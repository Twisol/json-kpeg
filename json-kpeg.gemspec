# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib/', __FILE__)
$:.unshift(lib) unless $:.include?(lib)

require 'json-kpeg/version'

Gem::Specification.new do |s|
  s.name = 'json-kpeg'
  s.version = JsonKpeg::VERSION
  s.license = 'MIT'
  s.author = 'Jonathan Castello'
  s.email = 'jonathan@jonathan.com'
  
  s.summary = 'A JSON parser implemented using kpeg.'
  s.description = 'A JSON parser implemented using kpeg.'
  
  s.files = Dir['lib/**/*'].reject {|f| f =~ /\.rbc$/}
  
  s.add_development_dependency 'bundler', '~> 1.0.0'
end
