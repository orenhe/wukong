#!/usr/bin/env ruby-1.9.3
EMR_CONFIG_DIR='.'
#$LOAD_PATH.unshift(File.expand_path(File.dirname("/Users/nimster/Code/wukong-nimster/"))) unless $LOAD_PATH.include?(File.expand_path(File.dirname("/Users/nimster/Code/wukong-nimster/")))

require 'rubygems'
require 'bundler/setup'

require 'wukong'

module Noop
  class Mapper < Wukong::Streamer::LineStreamer
    def process line
    end
  end
  class Reducer < Wukong::Streamer::ListReducer
    def finalize
    end
  end
end

Wukong::Script.new(
  Noop::Mapper,
  Noop::Reducer
).run # Execute the script
