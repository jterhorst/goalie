#!/usr/bin/ruby

require 'rubygems'
require 'json'
require 'net/http'
require "yaml"

## USAGE: ruby goalie.rb
## (you must add a goalie_settings.yml before this will work)

## Requirements: 
# ruby 2.0 or later
## sudo gem install json

## you'll need your Hockey app's ID and a token from your account with read-only access to the desired app
## HipChat v2 room notification token and room ID also required

## Place your app ID and tokens as YAML in goalie_settings.yml in this same dir, with this template:

# hockey:
#  app_id: hockey app id here
#  sdk_token: hockey sdk token

# hipchat:
#  room_token: room notification token
#  room_id: ID for the same room

$settings = YAML::load_file "goalie_settings.yml"

$thresholds = [50,100,150,200,250,500,1000] # points at which we trigger notifications. less than the lowest are ignored.
$thresholds.sort

$app_id = $settings['hockey']['app_id']
$hockey_sdk_token = $settings['hockey']['sdk_token']
$hipchat_token = $settings['hipchat']['room_token']
$room_number = $settings['hipchat']['room_id']

$crash_cache = ''
if File.exist?('crash_cache.yml')
	$crash_cache = YAML::load_file "crash_cache.yml"
end

def carlton_dance
	@payload = {
	    "color" => 'green',
	    "message" => "(dance) All major crashes cleared! http://media2.giphy.com/media/HblOOWbFjX8Ri/giphy.gif",
	    "notify" => false,
	    "message_format" => 'text'
	}.to_json

	url = "https://api.hipchat.com/v2/room/#{$room_number}/notification"
	uri = URI.parse(url)
	https = Net::HTTP.new(uri.host,uri.port)
	https.use_ssl = true
	req = Net::HTTP::Post.new(uri.path, initheader = {'Content-Type' => 'application/json', 'Authorization' => "Bearer #{$hipchat_token}"})
	req.body = @payload
	res = https.request(req)
end

def notify_total(total_crash_count)
	puts "#{total_crash_count} crash groups total"
	
	color = 'yellow'
	message = "(failed) #{total_crash_count} open crash issues remaining."
	if total_crash_count == 0
		color = 'green'
		message = "(success) 0 open crash issues remaining! http://myreactiongifs.com/gifs/thumbsupcomputerkid.gif"
	end

	@payload = {
	    "color" => color,
	    "message" => message,
	    "notify" => false,
	    "message_format" => 'text'
	}.to_json

	url = "https://api.hipchat.com/v2/room/#{$room_number}/notification"
	uri = URI.parse(url)
	https = Net::HTTP.new(uri.host,uri.port)
	https.use_ssl = true
	req = Net::HTTP::Post.new(uri.path, initheader = {'Content-Type' => 'application/json', 'Authorization' => "Bearer #{$hipchat_token}"})
	req.body = @payload
	res = https.request(req)
end

def notify(crash)
	# call up hipchat
	puts "[#{crash['bundle_version']}] #{crash['number_of_crashes']} occurrences - status: #{crash['status']} - #{crash['method']}"
	
	format = 'html'
	notify = true
	color = 'red'
	message = "<b>#{crash['number_of_crashes']} occurrences</b> of <a href=\"https://rink.hockeyapp.net/manage/apps/#{crash['app_id']}/crash_reasons/#{crash['id']}/multiple\">unresolved crash in <b>#{crash['bundle_short_version']} (#{crash['bundle_version']})</b></a>: <b>#{crash['class']}</b> <i>#{crash['method']}</i> #{crash['exception_type']} #{crash['reason']}"
	if crash['status'] != 0
		format = 'text'
		notify = false
		color = 'green'
		message = "(awwyiss) No longer unresolved: #{crash['number_of_crashes']} occurrences of crash in #{crash['bundle_short_version']} (#{crash['bundle_version']}): #{crash['class']} #{crash['method']}"
	end

	@payload = {
	    "color" => color,
	    "message" => message,
	    "notify" => notify,
	    "message_format" => format
	}.to_json

	url = "https://api.hipchat.com/v2/room/#{$room_number}/notification"
	uri = URI.parse(url)
	https = Net::HTTP.new(uri.host,uri.port)
	https.use_ssl = true
	req = Net::HTTP::Post.new(uri.path, initheader = {'Content-Type' => 'application/json', 'Authorization' => "Bearer #{$hipchat_token}"})
	req.body = @payload
	res = https.request(req)
	#puts "Response #{res.code} #{res.message}: #{res.body}" # debug your hipchat calls with this
end

def check_level(crash)
	# does this crash cross the threshold?
	crash_id = crash['id']
	crash_count = crash['number_of_crashes']

	new_threshold = 0 # see if the crash count is currently high enough
	$thresholds.each do |level|
		if level < crash_count
			new_threshold = level
		end
	end

	crash_old_threshold = 0 # where was the crash last time we checked?
	crash_old_count = 0;
	if $crash_cache.has_key?(crash_id)
		crash_old_count = $crash_cache[crash_id]
	end
	$thresholds.each do |level|
		if level < crash_old_count
			crash_old_threshold = level
		end
	end

	if new_threshold > crash_old_threshold
		$crash_cache[crash_id] = crash_count
		notify(crash)
	end
end

def check_resolved(crash)
	crash_id = crash['id']
	if $crash_cache.has_key?(crash_id)
		if crash['status'] != 0
			$crash_cache.delete(crash_id)
			notify(crash)
		end
	end
end

def check_crashes()

	# looping through the Hockey crash API: http://support.hockeyapp.net/kb/api/api-crashes

	current_page = 1
	total_pages = 1
	total_groups = 0;

	starting_count = $crash_cache.length

	while current_page <= total_pages
		url = URI("https://rink.hockeyapp.net/api/2/apps/#{$app_id}/crash_reasons?symbolicated=1&page=#{current_page}&per_page=100&sort=number_of_crashes&order=desc")

		resp = {}
		Net::HTTP.start(url.host, url.port, :use_ssl => url.scheme == 'https') do |http|
			request = Net::HTTP::Get.new(url)
			request.add_field('X-HockeyAppToken', $hockey_sdk_token)
			resp = http.request request
		end
		data = resp.body

		# we convert the returned JSON data to native Ruby
		# data structure - a hash
		result = JSON.parse(data)

		# if the hash has 'Error' as a key, we raise an error
		if result.has_key? 'Error'
		  raise "web service error"
		end
		
		crashes = result['crash_reasons']

		crashes.each do |crash_group|
			check_resolved(crash_group)
			if crash_group['status'] == 0
				check_level(crash_group)
			end
		end

		total_groups = total_groups + crashes.length

		# pagination
		if result['total_pages'] > total_pages
			total_pages = result['total_pages']
		end
		current_page = current_page + 1
	end

	if starting_count > 0
		notify_total(total_groups)
	end
	
	if $crash_cache.length == 0 && starting_count > 0
		carlton_dance
	end

	File.open("crash_cache.yml", "w") do |file|
		file.write $crash_cache.to_yaml
	end
end

puts "Calling Hockey for crashes in latest version...\n"

check_crashes()

puts "... done\n"

