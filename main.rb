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

  DHCPBinding = Struct.new :ip, :mac

  def dhcp_bindings
    doc = page_doc("net_dhcp_static_t")
    table_contents_inst doc, DHCPBinding, "IPAddr", "MACAddr"
  end

  DNSHost = Struct.new :name, :ip, :from_dhcp

  def dns_hosts
    doc = page_doc "app_dev_name_t"
    dhcp = table_contents_inst doc, DNSHost, "HostNamedhcp", "IPAddressdhcp"
    custom = table_contents_inst doc, DNSHost, "HostName", "IPAddress"
    dhcp.each { |h| h.from_dhcp = true }
    dhcp + custom
  end

  private def page_doc(page)
    Nokogiri::HTML.parse(request(:Get) { |r|
      r.page_uri = page
      r.expect Net::HTTPOK, page
    }.body)
  end

  private def table_contents_inst(doc, klass, *attrs)
    table_contents(doc, *attrs).map do |h|
      klass.new *attrs.map { |k| h.fetch k }
    end
  end

  private def table_contents(doc, *attrs)
    return enum_for :table_contents, doc, *attrs unless block_given?

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
      yield values.fetch(id)
    end
  end

  private def log_in!
    last_closed = nil
    loop do
      closed = attempt_log_in! or break
      closed != last_closed or raise "failed to closed existing session #{c}"
      last_closed = closed
    end
  end

  private def attempt_log_in!
    resp = do_request :Get
    form_val = -> key do
      resp.body[/\b#{Regexp.escape key}\b.+"(.+)"/, 1] \
        or raise "#{key} form value not found"
    end

    resp = do_request :Post do |r|
      r.form = {
        "action" => "login",
        "Username" => @login,
        "Password" => @passwd_digest,
        "Frm_Logintoken" => form_val["Frm_Logintoken"],
        "UserRandomNum" => @passwd_rand,
        "Frm_Loginchecktoken" => form_val["Frm_Loginchecktoken"],
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
    tbl = Nokogiri::HTML.parse(resp.body).css("#preempt-form").first \
      or raise "missing list of active sessions"
    $stderr.puts "already logged in elsewhere: %s" \
      % [tbl.css("label").map(&:text) * ", "]

    sess_id = tbl.css("input[type=radio]").first&.[](:value) \
      or raise "missing session radio input"
    sid = tbl.css("input[name=sid#{sess_id}]").first&.[](:value) \
      or raise "missing session SID input"

    resp = do_request :Post do |r|
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
    
    def page_uri=(name)
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

pp dhcp_bindings: router.dhcp_bindings
pp dns_hosts: router.dns_hosts
