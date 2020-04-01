require 'net_x/http_unix'
require 'json'
require 'pp'

class SimpleHTTP
  def initialize(uri, json: false)
    uri = URI uri if String === uri
    @client =
      case uri
      when URI
        uri.path.chomp("/") == "" or raise "non-root path unsupported"
        Net::HTTP.start uri.host, uri.port, use_ssl: uri.scheme == 'https'
      else
        uri
      end
    @type_config = TypeConf.new json: json
  end

  class TypeConf
    def initialize(opts)
      @json_in = @json_out = false
      update opts
    end

    attr_reader :json_in, :json_out

    def merge(opts)
      dup.update opts
    end

    def update(opts)
      opts = opts.dup
      @json_in = @json_out = opts.delete :json if opts.key? :json
      @json_in = opts.delete :json_in if opts.key? :json_in
      @json_out = opts.delete :json_out if opts.key? :json_out
      opts.empty? or raise "unrecognized opts: %p" % [opts.keys]
      self
    end
  end

  def get(path)
    request Net::HTTP::Get.new(path), expect: [Net::HTTPOK]
  end

  private def request(req, expect:, **opts)
    case resp = @client.request(req)
    when *expect
    else
      raise "unexpected response: #{resp.code} (#{resp.body})"
    end
    if @type_config.merge(opts).json_out
      JSON.parse resp.body
    else
      resp
    end
  end

  def patch(*args, **opts, &block)
    request_body Net::HTTP::Patch, *args, expect: [Net::HTTPOK], **opts, &block
  end

  private def request_body(cls, path, payload, expect:, **opts)
    req = cls.new path
    if @type_config.merge(opts).json_in && !payload.kind_of?(String)
      req['Content-Type'] = "application/json"
      payload = JSON.dump payload 
    end
    req.body = payload
    request req, expect: expect, **opts
  end
end

class DockerClient
  SOCK_PATH = "/var/run/docker.sock"
  API_VER = "1.40"

  def initialize
    @client = SimpleHTTP.new NetX::HTTPUnix.new('unix://' + SOCK_PATH),
      json: true
  end

  def get_json(path)
    @client.get path
  end
end

class Container
  def initialize(props)
    labels = Labels.new props.fetch "Labels"
    @traefik_enable = labels.lookup("traefik.enable") == "True"
    @service_name = labels.lookup("com.docker.compose.service")
    @private_port = determine_port(props.fetch("Ports"), labels)
  end

  attr_reader \
    :traefik_enable,
    :service_name,
    :private_port

  private def determine_port(ports, labels)
    key = "traefik.http.services.#{@service_name}.loadbalancer.server.port"
    labels.lookup(key)&.to_i \
      || ports.find { |p| p.fetch("Type") == "tcp" }&.fetch("PrivatePort")
  end
end

class Labels < Hash
  def initialize(labels)
    labels.each do |key,val|
      *parents, key = key.split(".")
      h = parents.inject(self) { |cur_h, key_part| cur_h[key_part] ||= {} }
      unless Hash === h
        raise "label tree at #{parents * "."} is already assigned"
      end
      if h.key? key
        raise "label at #{[*parents, key] * "."} already exists"
      end
      h[key] = val
    end
  end

  def lookup(*keys)
    keys = keys.flat_map { |k| k.split "." }
    keys.each_with_index.inject(self) do |h,(k,i)|
      unless Hash === h
        raise "label at #{keys[0,i] * "."} is not a hash (%p)" % [h]
      end
      h[k] or return
    end
  end

  attr_reader :labels
end

class CaddyClient
  def initialize(url, log:)
    @client = SimpleHTTP.new url, json: true
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
      ctn.traefik_enable or next
      port = ctn.private_port or next
      svc = ctn.service_name or next
      svc.length >= 1 or raise "invalid service name: %p" % [svc]
      !services.key?(svc) or raise "duplicate service: %p" % [svc]
      services[svc] = "#{svc}:#{port}"
    end

    caddy.set_config "/apps/http/servers/main/routes",
      services.map { |name, url|
        { match: [
            {host: conf["domains"].map { |d| "#{name}.#{d}" }},
          ],
          handle: [
            { handler: "reverse_proxy",
              upstreams: [{dial: url}] },
          ] }
      }

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
  require 'utils'
  Cmds.new(Utils::Conf.new "config.yml").cmd_gen
end
