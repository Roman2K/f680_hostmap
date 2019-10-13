require 'net/http'
require 'utils'
require 'digest'
require 'forwardable'
require 'cgi'
require 'nokogiri'

# ZTE F680 web interface client
class Router
  def initialize(url:, login:, password:)
    @uri = URI url
    @login = login
    @passwd_rand = ((rand * 89999999).round + 10000000).to_s
    @passwd_digest = Digest::SHA256.hexdigest(password + @passwd_rand)
  end

  DHCPBinding = Struct.new :id, :ip, :mac

  def dhcp_bindings
    request_page(:dhcp_bindings).table_contents_inst DHCPBinding,
      "IPAddr", "MACAddr"
  end

  DNSHost = Struct.new :id, :name, :ip, :from_dhcp

  def dns_hosts
    dns_hosts_from_page request_page(:dns_hosts)
  end

  private def dns_hosts_from_page(page)
    dhcp = page.table_contents_inst DNSHost, "HostNamedhcp", "IPAddressdhcp"
    custom = page.table_contents_inst DNSHost, "HostName", "IPAddress"
    dhcp.each { |h| h.id = nil; h.from_dhcp = true }
    dhcp + custom
  end

  class Page
    def initialize(resp)
      @resp = resp
    end

    def doc
      @doc ||= Nokogiri::HTML.parse @resp.body
    end

    def session_token
      @resp.body[/var session_token = "(\d+)"/, 1] \
        or raise "missing session token"
    end

    def table_contents_inst(klass, *attrs)
      table_contents(*attrs).map do |id, h|
        klass.new id, *attrs.map { |k| h.fetch k }
      end
    end

    def table_contents(*attrs)
      return enum_for :table_contents, *attrs unless block_given?

      val_re = attrs.map { |a| Regexp.escape a }.yield_self do |as|
        /\bTransfer_meaning\('(#{as.join "|"})(\d+)','(.+?)'\);/
      end

      values = doc.css("script").each_with_object({}) do |el, h|
        begin
          el.text =~ val_re
        rescue ArgumentError
          $!.message == "invalid byte sequence in UTF-8" or raise
          nil
        end or next
        (h[$2] ||= {})[$1] = $3.gsub(/\\x(..)/) { $1.to_i(16).chr }
      end

      attr0 = attrs.fetch 0
      doc.css("input[id^=#{attr0}]").each do |el|
        id = el[:id][/^#{Regexp.escape attr0}(\d+)/, 1] or next
        yield id, values.fetch(id)
      end
    end
  end

  def create_dns_host(new_h)
    !new_h.id or raise "existing record"
    !new_h.from_dhcp or raise "from_dhcp is irrelevant"

    page = request_page :Post, :dns_hosts do |r|
      r.form = {
        "_SESSION_TOKEN" => request_page(:dns_hosts).session_token,
        "IF_ACTION" => "new",
        "HostName" => new_h.name,
        "IPAddress" => new_h.ip,
      }
      r.expect Net::HTTPOK, "DNS host creation"
    end
    hosts = dns_hosts_from_page(page)
    created = hosts.
      find { |h| h.id && h.name == new_h.name && h.ip == new_h.ip } \
      or raise "failed to create"
    [created, hosts]
  end

  def del_dns_host(id)
    page = request_page :dns_hosts
    old_h = dns_hosts_from_page(page).find { |h| h.id == id }
    page = request_page :Post, :dns_hosts do |r|
      r.form = {
        "_SESSION_TOKEN" => page.session_token,
        "IF_ACTION" => "delete",
        "IF_INDEX" => id,
      }
      r.expect Net::HTTPOK, "DNS host deletion"
    end
    dns_hosts_from_page(page).tap do |hs|
      !old_h \
        || hs.none? { |h| h.id && h.name == old_h.name && h.ip == old_h.ip } \
        or raise "failed to delete"
    end
  end

  private def log_in!
    last_closed = nil
    loop do
      closed = attempt_log_in! or break
      closed != last_closed or raise "failed to closed existing session"
      last_closed = closed
    end
  end

  private def attempt_log_in!
    login_tok, login_tok_check = %w( Frm_Logintoken Frm_Loginchecktoken ).
      yield_self do |ks|
        body = do_request(:Get).body
        ks.map do |key|
          body[/\b#{Regexp.escape key}\b.+"(.+)"/, 1] \
            or raise "#{key} form value not found"
        end
      end

    resp = do_request :Post do |r|
      r.form = {
        "action" => "login",
        "Username" => @login,
        "Password" => @passwd_digest,
        "Frm_Logintoken" => login_tok,
        "UserRandomNum" => @passwd_rand,
        "Frm_Loginchecktoken" => login_tok_check,
      }
      r.expect Net::HTTPOK, Net::HTTPRedirection, "login"
    end

    @sid = CGI::Cookie.
      parse(resp["set-cookie"].tap { |s| s or raise "missing Set-Cookie" }).
      fetch("SID").fetch(0)

    if Net::HTTPRedirection === resp
      # Logged in successfully
      return
    end

    # List of currently active sessions: close the first one and try again
    tbl = Page.new(resp).doc.css("#preempt-form").first \
      or raise "missing list of active sessions"
    $stderr.puts "already logged in elsewhere: %s" \
      % [tbl.css("label").map(&:text) * ", "]

    sess_id = tbl.css("input[type=radio]").first&.[](:value) \
      or raise "missing session radio input"
    sid = tbl.css("input[name=sid#{sess_id}]").first&.[](:value) \
      or raise "missing session SID input"

    do_request :Post do |r|
      r.form = {
        "action" => "preempt",
        "index" => sess_id,
        "sid#{sess_id}" => sid,
      }
      r.expect Net::HTTPRedirection, "logout"
    end

    $stderr.puts "closed other session"
    sess_id
  end

  private def request_page(type, page=nil)
    # Handle these calls:
    #
    #   request_page "app_dev_name_t"
    #   request_page :dns_hosts
    #   request_page :Get, "app_dev_name_t"
    #   request_page :Post
    #
    type, page = :Get, type if type[0] !~ /^[A-Z]/ && page.nil?
    resp = request(type) do |r|
      if page
        r.page_uri = page
        r.expect Net::HTTPOK, page
      end
      yield r if block_given?
    end
    Page.new resp
  end

  private def request(*args, &block)
    @sid or log_in!
    do_request *args, &block 
  end

  private def do_request(type)
    req = Request.new(type, @uri)
    yield req if block_given?
    req["Cookie"] = [req["Cookie"], "_TESTCOOKIESUPPORT=1"].
      compact.
      tap { |arr| arr << "SID=#{@sid}" if @sid }.
      join "; "
    req.perform
  end

  class Request
    def initialize(type, uri)
      @orig_uri = @uri = uri
      @req = -> { Net::HTTP.const_get(type).new @uri }
    end

    def set_uri
      raise "uri can't be modified" unless Proc === @req
      yield(@uri = @orig_uri.dup)
    end

    PAGE_NAMES = {
      dhcp_bindings: "net_dhcp_static_t",
      dns_hosts: "app_dev_name_t",
    }.freeze
    
    def page_uri=(name)
      name = PAGE_NAMES.fetch name if Symbol === name
      set_uri do |u|
        u.path += "/getpage.gch"
        u.query = "pid=1002&nextpage=#{name}.gch"
      end
    end

    def form=(data)
      final_req.set_form_data data
    end

    def expect(*types, action)
      @expect = types
      @expect_action = action
    end

    private def final_req
      @req = @req.call if Proc === @req
      @req
    end

    extend Forwardable
    def_delegators :final_req, :[], :[]=

    def perform
      h, p, ssl = @uri.host, @uri.port, @uri.scheme == 'https'
      Net::HTTP.
        start(h, p, use_ssl: ssl) { |http| http.request final_req }.
        tap { |resp|
          @expect && @expect.size > 0 or next
          case resp
          when *@expect
          else raise "unexpected %s response: %s" % [@expect_action, resp.code]
          end
        }
    end
  end
end

config = Utils::Conf.new "config.yml"
router = Router.new url: config["router.url"],
  **config["router.credentials"].slice(:login, :password)

# pp dhcp_bindings: router.dhcp_bindings
puts "\ncreating"
h, list = router.create_dns_host Router::DNSHost[nil, "winpc6", "192.168.1.110"]
pp after_create: list

if id = list.find { |h| h.name == "winpc3" }&.id
  puts "\ndeleting id=#{id}"
  list = router.del_dns_host id
  pp after_del: list
end
