require 'net/http'
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

def dhcp_leases;    Sections::DHCPLeases.new self end
def dhcp_bindings;  Sections::DHCPBindings.new self end
def dns_hosts;      Sections::DNSHosts.new self end

def self.[](section, *args)
  Sections.const_get(section)::Record.new(nil, *args)
end

module Sections
  class BasicSection
    def initialize(router)
      @router = router
    end

    def create(new)
      !new.id or raise "existing record"

      page = request_page :Post, self.class::PAGE do |r|
        r.form = {
          "_SESSION_TOKEN" => request_page(self.class::PAGE).session_token,
          "IF_ACTION" => "new",
        }.merge(new.form_values)
        r.expect Net::HTTPOK, "#{self.class::RECORD_DESC} creation"
      end
      all = records_from_page(page)

      created = all.find { |r| r.id && r.form_values == new.form_values } \
        or raise "failed to create %s %p" \
          % [self.class::RECORD_DESC, new.form_values]

      [created, all]
    end

    def all
      records_from_page(request_page self.class::PAGE)
    end

    def delete(id)
      if self.class::Record === id
        id = id.id or raise "can't delete new record"
      end

      page = request_page self.class::PAGE
      old = records_from_page(page).find { |h| h.id == id }

      page = request_page :Post, self.class::PAGE do |r|
        r.form = {
          "_SESSION_TOKEN" => page.session_token,
          "IF_ACTION" => "delete",
          "IF_INDEX" => id,
        }
        r.expect Net::HTTPOK, "#{self.class::RECORD_DESC} deletion"
      end
      all = records_from_page(page)
      
      !old \
        || all.none? { |r| r.id && r.form_values == old.form_values } \
        or raise "failed to delete"

      [old, all]
    end

    protected def form_keys
      @form_keys ||= self.class::Record.new.form_values.keys
    end

    private def request_page(*args, &block)
      @router.request_page *args, &block
    end
  end

  module BasicRecord
    def to_s
      class_desc = (self.class.name[/.+::/] or raise "unexpected namespacing").
        chomp("::").
        split("::").
        inject(Object) { |c,n| c.const_get n }::RECORD_DESC

      "%s%s %s" % [class_desc, (id ? "##{id}" : "*"), desc]
    end
  end

  class DHCPBindings < BasicSection
    PAGE = :dhcp_bindings
    RECORD_DESC = "DHCP binding"

    Record = Struct.new :id, :ip, :mac do
      include BasicRecord

      def form_values
        { "IPAddr" => ip,
          "MACAddr" => mac }
      end

      protected def desc
        "#{ip} @ #{mac}"
      end
    end

    protected def records_from_page(page)
      page.table_contents_inst Record, *form_keys
    end
  end

  class DNSHosts < BasicSection
    PAGE = :dns_hosts
    RECORD_DESC = "DNS host"

    Record = Struct.new :id, :name, :ip, :from_dhcp do
      include BasicRecord

      def form_values
        { "HostName" => name,
          "IPAddress" => ip }
      end

      protected def desc
        "#{name} @ #{ip}".tap { |s|
          s << " [DHCP]" if from_dhcp
        }
      end
    end

    def create(h)
      !h.from_dhcp or raise "from_dhcp is irrelevant"
      super
    end

    protected def records_from_page(page)
      dhcp = page.table_contents_inst Record, "HostNamedhcp", "IPAddressdhcp"
      custom = page.table_contents_inst Record, "HostName", "IPAddress"
      dhcp.each { |h| h.id = nil; h.from_dhcp = true }
      dhcp + custom
    end
  end

  class DHCPLeases < BasicSection
    PAGE = "net_dhcp_dynamic_t"

    Record = Struct.new :id, :mac, :ip, :time, :port, :name

    protected def records_from_page(page)
      page.table_contents_inst Record,
        *%w( MACAddr IPAddr ExpiredTime PhyPortName ),
        opt: %w( HostName )
    end
  end
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

  def table_contents_inst(klass, *attrs, opt: [])
    table_contents(*attrs).map do |id, h|
      klass.new id, *attrs.map { |k| h.fetch k }, *opt.map { |k| h[k] }
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

private def log_in!
  last_closed = nil
  loop do
    closed = attempt_log_in! or break
    closed != last_closed or raise "failed to closed existing session"
    last_closed = closed
  end
end

private def attempt_log_in!
  login_tok, login_tok_check = %w(Frm_Logintoken Frm_Loginchecktoken).
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

def request_page(type, page=nil)
  ##
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
        @expect or next
        case resp
        when *@expect
        else raise "unexpected %s response: %s" % [@expect_action, resp.code]
        end
      }
  end
end

end # Router
