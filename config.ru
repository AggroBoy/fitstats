require 'rubygems'
require 'bundler'

Bundler.require

require './fitstats.rb'
run Sinatra::Application

