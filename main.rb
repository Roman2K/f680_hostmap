require 'utils'
require_relative 'router'

class ConfigUpdate
  def initialize(dhcp, dns)
    @dhcp = dhcp
    @dns = dns.reject(&:from_dhcp)
  end

  Binding = Struct.new :mac, :names
  Diff = Struct.new :dhcp_new, :dhcp_del, :dns_new, :dns_del

  def diff(bindings, ip_range)
    dhcp = {}
    bindings.each do |want|
      b = @dhcp.find { |b|
        b.mac.downcase == want.mac.downcase && ip_range.cover?(IPAddr.new b.ip)
      } || Router[:DHCPBindings, nil, want.mac]
      dns = want.names.map { |name|
        @dns.find { |h| h.name == name } || Router[:DNSHosts, name]
      }
      dhcp[b] = dns
    end

    # Assign IPs
    seq = ip_range.each
    used = Set.new(dhcp.keys.map { |b| b.ip and IPAddr.new b.ip }.compact)
    next_ip = -> do
      begin
        seq.next
      rescue StopIteration
        raise "run out of IPs - used #{used.size} of #{ip_range.count}"
      end
    end
    dhcp.each_key do |b|
      !b.ip or next
      begin; free = next_ip[] end while used.include? free
      b.ip = free.to_s
      used << free
    end

    # Assign DNS names
    dhcp.each do |b, dns|
      dns.map! do |host|
        host.ip == b.ip ? host : Router[:DNSHosts, host.name, b.ip]
      end
    end

    Diff.new.tap do |d|
      d.dhcp_del, d.dhcp_new = dhcp.keys.yield_self do |bs|
        old, new = bs.partition &:id
        [@dhcp - old, new]
      end
      d.dns_del, d.dns_new = dhcp.flat_map { |b, dns| dns }.yield_self do |dns|
        old, new = dns.partition &:id
        [@dns - old, new]
      end
    end
  end
end

def progress(title, arr)
  puts = -> s, idx=nil do
    pct = Utils::Fmt.pct((idx + 1).to_f / arr.size, 0) if idx
    Kernel.puts "%s%s: %s" % [title, (" #{pct}" if pct), s]
  end

  puts["..."]
  arr.each_with_index do |el, idx|
    yield el
    puts[el, idx]
  end
  puts["done"]
end

config = Utils::Conf.new "config.yml"
router = Router.new url: config["router.url"],
  **config["router.credentials"].slice(:login, :password)
ip_range = Range.new *config["dhcp.range"].values_at(:start, :end).
  map { |addr| IPAddr.new addr }
bindings = config["dhcp.bindings"].to_hash

diff = ConfigUpdate.new(
  router.dhcp_bindings.all,
  router.dns_hosts.all,
).diff(
  bindings.map { |name, b|
    ConfigUpdate::Binding[b[:mac], [name.to_s, *b.lookup(:aliases)]]
  }.tap { |bs|
    pp bindings: bs
  },
  ip_range,
)
pp diff: diff.to_h.transform_values { |arr| arr.map &:to_s }

progress(:dhcp_del, diff.dhcp_del) { |b| router.dhcp_bindings.delete b }
progress(:dns_del, diff.dns_del) { |h| router.dns_hosts.delete h }
progress(:dhcp_new, diff.dhcp_new) { |b| router.dhcp_bindings.create b }
progress(:dns_new, diff.dns_new) { |h| router.dns_hosts.create h }
