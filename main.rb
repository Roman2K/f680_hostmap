require 'utils'
require_relative 'router'

config = Utils::Conf.new "config.yml"
router = Router.new url: config["router.url"],
  **config["router.credentials"].slice(:login, :password)

# pp dhcp_bindings: router.dhcp_bindings.all
# puts "creating", c = Router[:DHCPBindings, "192.168.1.6", "dd:dd:dd:dd:dd:dd"]
  
# pp creating: c
# created, list = router.dhcp_bindings.create c
# pp created: created
# pp after_create: list

# list.reverse_each do |b|
#   old, list = router.dhcp_bindings.delete b
#   pp old: old, deleted: b
# end
# pp after_delete: list

list = nil
(2..2).each do |n|
  pp creating: h = Router[:DNSHosts, "winpc#{n}", "192.168.1.110"]
  created, list = router.dns_hosts.create h
  pp created: h
end
pp after_create: list

list = nil
router.dns_hosts.all.reverse_each do |h|
  h.id or next
  pp deleting: h
  _, list = router.dns_hosts.delete h
end
pp after_delete: list
