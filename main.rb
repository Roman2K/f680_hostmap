require 'utils'
require_relative 'router'

config = Utils::Conf.new "config.yml"
router = Router.new url: config["router.url"],
  **config["router.credentials"].slice(:login, :password)

pp dhcp_bindings: router.dhcp_bindings.all
puts "creating",
  c = Router::Sections::DHCPBindings::Record.new(nil, "192.168.1.6", "dd:dd:dd:dd:dd:dd")
pp creating: c
created, list = router.dhcp_bindings.create c
pp created: created
pp after_create: list

list.reverse_each do |b|
  old, list = router.dhcp_bindings.delete b
  pp old: old, deleted: b
end
pp after_delete: list

# list = nil
# (2..2).each do |n|
#   h, list = router.dns_hosts.create \
#     Router::Sections::DNSHosts::Record[nil, "winpc#{n}", "192.168.1.110"]
#   pp created: h
# end
# pp after: list

# list = nil
# router.dns_hosts.all.reverse_each do |h|
#   h.id or next
#   puts "\ndeleting #{h}"
#   list = router.dns_hosts.delete h.id
# end
# pp after_delete: list

# pp dns_hosts: router.dns_hosts.all
