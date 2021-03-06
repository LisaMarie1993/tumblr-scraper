#!/usr/bin/env ruby
require 'rubygems'
require 'timeout'
require 'bundler'
require 'uri'
require 'thread'
require 'yaml'
require 'digest/md5'
Bundler.require

$site = ARGV[0]
$site = $site.split('/').pop
$start = Time.new
directory = ARGV[1] ? ARGV[1] : $site
$queue = Queue.new
$badFile = Queue.new
$imageDownload = true
$maxgraph = 130
$bytes = 0

concurrency = 13

# Create the directory from the base directory AND the tumblr site
directory = [directory, $site].join('/')

# Create a log and graph directory
logs = [directory, 'logs'].join('/')
graphs = [directory, 'graphs'].join('/')

puts "Downloading photos from #{$site.inspect}, concurrency=#{concurrency} ..."

# Make the download directory
=begin
if File.exists? directory
  puts "skipping for now..."
  exit 0
end
=end

FileUtils.mkdir_p(directory)

# Make the log directory
FileUtils.mkdir_p(logs)
FileUtils.mkdir_p(graphs)

threads = []
$allImages = []
$connection = Curl::Easy.new do | curl |
 curl.headers["Connection"] = "keep-alive"
 # Enable deflate and gzip
 curl.encoding = ''
 curl.follow_location = true
end
$filecount = 0

# The predictive key to get the notes (see below)
$pkNote = false

def download(url, local = '', connection = $connection)

  if local.length > 0 and File.exists?(local) and File.size(local) > 0
    content = ''
    File.open(local, 'r') { | f | content = f.read } 
    return [true, content, true] 
  end

  connection.url = url

  page = false
  tries = 6

  connection.on_failure { | handle, x |
    # Trying to discover the kinds of errors we get
    File.open("#{directory}/errors", 'a') { | f |
      f.write(YAML::dump(handle))
      f.write(YAML::dump(x))
    }
  }
  loop {
    tries -= 1

    begin
      connection.perform 
      page = connection.body_str
      return [false, 0, false] if connection.status.scan(/^404/).length > 0
      break

    rescue Exception => ex
      puts "Error (#{url}), #{$!}"

      if tries > 0
        puts "Trying again (#{tries} left)"
        sleep 1
        next
      end

      break
    end
  }

  $filecount += 1
  if page
    $bytes += page.length
    duration = Time.new - $start
    mb = $bytes / (1024.00 * 1024.00)
    speed = ($bytes / duration) / 1024
    files_per_minute = ($filecount.to_f / duration)
    puts "%4d %4.2fM %.0f:%02d %3.0fK/%3.1fF %s %s" % [
      $queue.length * $maxgraph, 
      mb, 
      (duration / 60).floor, 
      duration.to_i % 60, 
      speed, 
      files_per_minute,
      url, local]
    STDOUT.flush

    File.open(local, 'w') { | f | f.write(page) } if local.length > 0 and page.length > 0
  else
    puts YAML::dump(page)
    exit
  end
 
  [true, page, false]
end

def parsevideo(page)
  all = [] 
  page.scan(/url="([^"]*)"/) { | list | 
    list.each { | x |
      all << x
      $queue << [:video, x]
    }
  }

  doc = Nokogiri::XML.parse(page)
  posts = (doc/'post').map {|x| x['url']}
  posts.each do | url |
    $queue << [:page, url]
  end

  all
end

def parsefile(doc)
  images = (doc/'post photo-url').select{|x| x if x['max-width'].to_i == 1280 }
  posts = (doc/'post').map {|x| x['url']}
  image_urls = images.map {|x| x.content }

  # Eliminate duplicate images.
  image_urls.sort!
  image_urls.uniq!
  
  # Eliminate images we've already downloaded
  image_urls = image_urls - $allImages

  # Add this to the list
  $allImages += image_urls
  $allImages += posts

  posts.each do | url |
    $queue << [:page, url]
  end

#  image_urls.each do |url|
#    $queue << [:image, url]
#  end

  [images, image_urls]
end

logList = Dir.glob("#{logs}/*") 
ix = 0
last = 0
logList.each { | file |

  ix += 1
  if ( ix * 100 / logList.length ) > (last + 5)
    if [0, 50].include? last
      print "#{last}%"
    else
      print "."
    end
    last += 5
    STDOUT.flush
  end

  next if file == 'posts.json'

  if file == "badurl"

    File.open(file, 'r') { | content |
      # Start the list with the bad images
      $allImages = content.split('\n')
    }

  else
    File.open(file, 'r') { | content |
      images, count = parsefile Nokogiri::XML.parse(content)
    }

  end
}
print "100% (#{$allImages.length} objects loaded)\n" if last > 0

# Feed in the key
if File.exists?("#{directory}/keys")
  File.open("#{directory}/keys", 'r') { | f |
    contents = f.read.split("\n")
    $pkNote = contents.last.strip
    print "Key = #{$pkNote} \n"
  }
end

def graphGet(file)
  file.scan(/'(\/notes\/[^\']*)',/) { | x | 
    return ['http://', $site, x].join('')
  }
  false
end

concurrency.times do | x | 
  threads << Thread.new {

    whoami = x

    connection = Curl::Easy.new do | curl |
      curl.headers["Connection"] = "keep-alive"
      curl.encoding = ''
      curl.follow_location = true
    end

    # Make sure we know about failures.
    Thread.abort_on_exception = true

    loop {
      begin
        ctype = false
        url = false
        Timeout::timeout(45) do
          # Only get the low-priority requests if the high
          # priority ones are done
          ctype, url = $queue.pop
          ## ^^ There *may* be a race condition here that leads to a dead-lock
        end

        #puts "#{$queue.length} [Queue] #{type} #{url}"
        if ctype == :control
          puts ">> Stopping #{url} <<\n"
          break
        end

      rescue Timeout::Error => ex
        puts ">> TIMEOUT Stopping #{whoami} <<\n"
        break

      rescue
        puts "Queue failure, trying again, #{$!}"
        next

      end

      filename = url.split('/').pop

      if ctype == :video
        videoList = []
        success, page, local = download(url, "#{graphs}/#{filename}", connection)

        page.scan(/source src=.x22([^\\]*)/) { | list |
          list.each { | x |
            videoList << x if x.match(/video_file/)
          }
        }

        videoList.each { | url |
          
          File.open("#{directory}/vids", 'a') { | f |
            realurl=`curl -sI #{url} | grep ocation | awk ' { print $2 } '`
            f.write("#{realurl.gsub(/#.*/, '')}")
          }
        }

      elsif ctype == :image
        next
        success, file, local = download(url, "#{directory}/#{filename}", connection) if $imageDownload

      elsif ctype == :page
        page = 0
        if $pkNote
          uri = URI(url)
          url = "http://#{uri.host}/notes/#{filename}/#{$pkNote}?from_c=#{Time.now.to_i + 60 * 60 + 24}"
        end

        loop {
          # Get out of here if the collapsed form has been processed
          break if File.exists? "#{graphs}/#{filename}.json"

          fname = "#{graphs}/#{filename}.#{page}"
          
          success, file, local = download(url, fname, connection)

          $pkNote = false if file == 0 or file.length == 0

          # tumblr notes use some kind of private key to avoid predictive grabbing.
          # but it's identical for a blog. So once we see it, we can store it and then
          # do predictive grabbing from here on out. 
          if !$pkNote and url and page > 1
            puts url
            uri = URI(url)
            $pkNote = uri.path.split('/').pop

            # Trying to discover if the keys change
            File.open("#{directory}/keys", 'a') { | f |
              f.write("#{$pkNote}\n")
            }
          end

          if success
            url = graphGet(file) 
          else
            puts "Error getting #{url}"
          end


          ## Just get the recent history... no need to go crazy
          break unless url and success and page < $maxgraph

          page += 1
        }
      end
    }
  }
end

num = 50
start = 0
loop do
  page_url = "http://#{$site}/api/read?type=photo&num=#{num}&start=#{start}"

  success, page, local = download(page_url)

  if !success
    puts "Failed to get #{page_url} - site likely gone"
    exit 
  end

  doc = Nokogiri::XML.parse(page)
  md5 = Digest::MD5.hexdigest(page)
  logFile = [logs, md5].join('/')

  break if File.exists?(logFile)

  images, added = parsefile doc

  # If this file added nothing, then break here and don't save it.
  break if added.count == 0
  
  # Log the content that we are getting
  File.open(logFile, 'w') { | f | f.write(doc.to_s) }

  break if images.count < num

  start += num
end
puts "All image feeds downloaded."

num = 50
start = 0
loop do
  page_url = "http://#{$site}/api/read?type=video&num=#{num}&start=#{start}"

  success, page, local = download(page_url)

  if !success
    puts "Failed to get #{page_url}"
    break
  end

  md5 = Digest::MD5.hexdigest(page)
  logFile = [logs, md5].join('/')

  break if File.exists?(logFile)

  videos = parsevideo page
  start += num

  File.open(logFile, 'w') { | f | f.write(page) }
  
  break if videos.count < num
end

puts "All feeds downloaded."

(2 * concurrency).times do | x | 
  $queue << [:control, x.to_s]
end

threads.each { |t| t.join }

puts "Ok done. Adding 403s to blacklist"

File.open("#{logs}/badurl", "w+") { | f | 
  loop {
    break if $badFile.empty?
    f.write( $badFile.pop )
  }
}
