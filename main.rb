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

  def dhcp_bindings
    resp = request :Get do |r|
      r.set_uri do |u|
        u.path += "/getpage.gch"
        u.query = "pid=1002&nextpage=net_dhcp_static_t.gch"
      end
    end
    Net::HTTPOK === resp or raise "unexpected response: #{resp}"

    doc = Nokogiri::HTML.parse(resp.body)
    values = doc.css("script").each_with_object({}) do |el, h|
      begin
        el.text =~ /\bTransfer_meaning\('(IPAddr|MACAddr)(\d+)','(.+?)'\);/
      rescue ArgumentError
        $!.message == "invalid byte sequence in UTF-8" or raise
        nil
      end or next
      (h[$2] ||= {})[$1] = $3.gsub(/\\x(..)/) { $1.to_i(16).chr }
    end

    doc.css("input[id^=IPAddr]").each_with_object [] do |el, arr|
      id = el[:id][/^IPAddr(\d+)/, 1] or next
      vs = values.fetch(id)
      arr << DHCPBinding[vs.fetch("IPAddr"), vs.fetch("MACAddr")]
    end
  end

  DHCPBinding = Struct.new :ip, :mac

  private def log_in!
    last_closed = nil
    loop do
      closed = attempt_log_in! or break
      closed != last_closed or raise "failed to closed existing session #{c}"
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
    end

    @sid = CGI::Cookie.
      parse(resp["set-cookie"].tap { |s| s or raise "missing Set-Cookie" }).
      fetch("SID").fetch(0)

    case resp
    when Net::HTTPRedirection
      # Logged in
      return
    when Net::HTTPOK
      # Already logged in else where
    else
      raise "unexpected login response: #{resp}"
    end

    # List of currently active sessions: close the first one and try again
    doc = Nokogiri::HTML.parse resp.body
    tbl = doc.css("#preempt-form").first \
      or raise "missing list of active sessions"
    $stderr.puts "already logged in elsewhere: %s" \
      % [tbl.css("label").map(&:text) * ", "]

    sess_id = doc.css("input[type=radio]").first&.[](:value) \
      or raise "missing session radio input"
    sid = doc.css("input[name=sid#{sess_id}]").first&.[](:value) \
      or raise "missing session SID input"

    resp = do_request :Post do |r|
      r.form = {
        "action" => "preempt",
        "index" => sess_id,
        "sid#{sess_id}" => sid,
      }
    end
    Net::HTTPRedirection === resp or raise "unexpected logout response: #{resp}"

    $stderr.puts "closed other session"
    sess_id
  end

  private def request(*args, &block)
    @sid or log_in!
    do_request *args, &block 
    # TODO detect session timeout
  end

  private def do_request(type)
    Request.new(type, @uri).tap { |req|
      yield req if block_given?
      req["Cookie"] = [req["Cookie"], "_TESTCOOKIESUPPORT=1"].
        compact.
        tap { |arr| arr << "SID=#{@sid}" if @sid }.
        join "; "
    }.perform
  end

  class Request
    def initialize(type, uri)
      @uri = uri.dup
      @req = -> { Net::HTTP.const_get(type).new @uri }
    end

    def set_uri
      raise "uri can't be modified" unless Proc === @req
      yield @uri
    end

    def form=(data)
      final_req.set_form_data data
    end

    private def final_req
      @req = @req.call if Proc === @req
      @req
    end

    extend Forwardable
    def_delegators :final_req, :[], :[]=

    def perform
      h, p, ssl = @uri.host, @uri.port, @uri.scheme == 'https'
      Net::HTTP.start(h, p, use_ssl: ssl) { |http| http.request final_req }
    end
  end
end

config = Utils::Conf.new "config.yml"
router = Router.new url: config["router.url"],
  **config["router.credentials"].slice(:login, :password)

pp dhcp_bindings: router.dhcp_bindings
