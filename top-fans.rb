#!/usr/bin/env ruby
#
# top-fans will take a stdin list of collapsed graphs (see note-collapse)
# read through the posts, and then print out the top rebloggers
# and fans from all those in stdin.
#
# By using stdin, this allows one to read over multiple blogs.
#
require 'rubygems'
require 'bundler'
Bundler.require

$start = Time.new

header = true
if ARGV.length > 0
  header = false
end

count = 0

limit = (ARGV[0] || 35).to_i

whoMap = {}
likeMap = {}
reblogMap = {}

$stdin.each_line { | file |
  file.strip!
  count += 1

  if count % 200 == 0 and header
    $stderr.putc "."
  end

  File.open(file, 'r') { | content |
    JSON.parse(content.read)[0..200].each { | entry |
      if entry.is_a?(String)
        who = entry
        likeMap[who] = 1 + (likeMap[who] || 0)
      else
        who, source, post = entry
        print "#{who} "
        reblogMap[who] = 1 + (reblogMap[who] || 0)
      end
      whoMap[who] = 1 + (whoMap[who] || 0)
    }
  } 
}

limit = [whoMap.length, likeMap.length, reblogMap.length, limit].min - 1

top = [whoMap, likeMap, reblogMap].map { | which |
  which.sort_by { | who, count | count }.reverse[0..limit]
}.transpose

if header
  printf "\n %-31s %-30s %s\n", "total", "likes", "reblogs"
  top.each { | row |
    row.each { | who, count |
      printf "%5d %-25s", count, who
    }
    printf "\n"
  }
else
  top.each { | row |
    print "#{row[0][0]}.tumblr.com\n"
  }
end
