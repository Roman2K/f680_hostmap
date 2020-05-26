require 'net_x/http_unix'
require 'pp'
require 'utils'

class DockerClient
  SOCK_PATH = "/var/run/docker.sock"
  API_VER = "1.40"

  def initialize
    @client = Utils::SimpleHTTP.new NetX::HTTPUnix.new('unix://' + SOCK_PATH),
      json: true
  end

  def get_json(path)
    @client.get path
  end
end

class Container
  def initialize(props)
    labels = props.fetch "Labels"
    @traefik_enable = labels["traefik.enable"] == "True"
    @service_name = labels["com.docker.compose.service"]
    @private_port = determine_port(props.fetch("Ports"), labels)
    @oneoff = labels["com.docker.compose.oneoff"] == "True"
  end

  attr_reader \
    :traefik_enable,
    :service_name,
    :private_port,
    :oneoff

  private def determine_port(ports, labels)
    key = "traefik.http.services.#{@service_name}.loadbalancer.server.port"
    labels[key]&.to_i \
      || ports.find { |p| p.fetch("Type") == "tcp" }&.fetch("PrivatePort")
  end
end

class CaddyClient
  def initialize(url, log:)
    @client = Utils::SimpleHTTP.new url, json: true
    @log = log["caddy"]
  end

  def config
    @client.get "/config/"
  end

  def set_config(path, config)
    @log.info "updating config:\n%s" % [PP.pp(config, "")]
    @client.patch "/config#{path}", config, expect: [Net::HTTPOK],
      json_out: false
  end
end

class Cmds
  ALIASES_CONF_PATH = "config.dev_aliases.yml"

  def initialize(config)
    @config = config
    @log = Utils::Log.new
  end

  def cmd_gen
    services = update_caddy
    gen_aliases_conf(services)
  end

  private def update_caddy
    conf = @config["caddy"]
    caddy = CaddyClient.new conf["admin_url"], log: @log
    docker = DockerClient.new

    services = conf["services.static"].to_hash
    docker.get_json("/containers/json").each do |props|
      ctn = Container.new props
      next unless ctn.traefik_enable && !ctn.oneoff
      port = ctn.private_port or next
      svc = ctn.service_name or next
      svc.length >= 1 or raise "invalid service name: %p" % [svc]
      raise "duplicate service: %p" % [svc] if services.key? svc
      services[svc] = "#{svc}:#{port}"
    end

    caddy.set_config("/apps/http/servers/main/routes",
      services.map { |name, url|
        { match: [
            {host: conf["domains"].map { |d| "#{name}.#{d}" }},
          ],
          handle: [
            { handler: "reverse_proxy",
              upstreams: [{dial: url}] },
          ] }
      }
    ) unless conf["ro"]

    services
  end

  private def gen_aliases_conf(services)
    names = (@config["caddy.services.extras"] + services.keys).map(&:to_s).uniq
    out = ALIASES_CONF_PATH
    @log[out: out, names: names].info "writing config file"
    File.open out, 'w' do |f|
      YAML.dump names, f
    end
  end
end

if $0 == __FILE__
  Cmds.new(Utils::Conf.new "config.yml").cmd_gen
end
