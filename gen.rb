require 'yaml'

IN = "docker-compose.yml"
OUT = "config.dev_aliases.yml"
STATIC_NAMES = %w(
  traefik
  wis-squid
  qbt
)

conf = File.open(IN, 'r') { |f| YAML.load f }
names = STATIC_NAMES.dup
conf.fetch("services").each do |name, s|
  if s.fetch("labels", {})["traefik.enable"]
    names << name
  end
end

File.open OUT, 'w' do |f|
  [$stdout, f].each do |io|
    YAML.dump names, io
  end
end
