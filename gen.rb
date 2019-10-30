require 'net/http'
require 'json'
require 'yaml'
require 'set'

ROUTERS_URL = "http://traefik.home/api/http/routers".freeze
OUT = "config.dev_aliases.yml".freeze
STATIC_NAMES = %w(
  wis-squid
).freeze

routers = JSON.parse(Net::HTTP.get_response(URI(ROUTERS_URL)).tap { |r|
  Net::HTTPOK === r or raise "unexpected response"
}.body)

names = Set.new(STATIC_NAMES).tap { |set|
  routers.each do |r|
    r.fetch("rule").scan(/`(.+?)\.home`/) do
      set << $1
    end
  end
}.to_a

File.open OUT, 'w' do |f|
  [$stdout, f].each do |io|
    YAML.dump names, io
  end
end
