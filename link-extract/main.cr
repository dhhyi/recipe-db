require "file_utils"
require "http/client"
require "http/server"
require "json"
require "uri"
require "xml"

struct PageMetaData
  include JSON::Serializable

  property url : String
  property favicon : String?
  property title : String?
  property description : String?
  property canonical : String?

  def initialize(@url : String, @favicon : String?, @title : String?, @description : String?, @canonical : String?)
  end
end

# RFC 9457 Problem Details body, mirroring the recipes service's error shape.
struct ProblemDetails
  include JSON::Serializable

  property type : String
  property title : String
  property status : Int32
  property detail : String
  property code : String

  def initialize(@title : String, @status : Int32, @detail : String, @code : String)
    @type = "about:blank"
  end
end

def send_problem(response : HTTP::Server::Response, status : Int32, title : String, detail : String, code : String)
  response.status_code = status
  response.content_type = "application/problem+json"
  ProblemDetails.new(title, status, detail, code).to_json(response)
end

class InvalidUrlError < Exception
end

class Cache
  @db_file : String

  def initialize(location : String?)
    @db_file = if location
                 location.ends_with?(".json") ? location : File.join(location, "db.json")
               else
                 "./db.json"
               end

    FileUtils.mkdir_p(File.dirname(@db_file))
    puts "Database location: #{@db_file}"
  end

  def find_one(url : String) : PageMetaData?
    read_entries.find { |entry| entry.url == url }
  end

  def insert_one(meta : PageMetaData)
    File.open(@db_file, "a+") do |file|
      file.flock_exclusive
      file.rewind
      content = file.gets_to_end
      entries = parse_entries(content)
      entries << meta
      file.truncate
      file.rewind
      entries.to_json(file)
    ensure
      file.try &.flock_unlock
    end
  end

  private def read_entries : Array(PageMetaData)
    return [] of PageMetaData unless File.exists?(@db_file)

    File.open(@db_file, "r") do |file|
      file.flock_shared
      parse_entries(file.gets_to_end)
    ensure
      file.try &.flock_unlock
    end
  end

  private def parse_entries(content : String) : Array(PageMetaData)
    return [] of PageMetaData if content.blank?

    Array(PageMetaData).from_json(content)
  rescue JSON::ParseException
    [] of PageMetaData
  end
end

def validate_url(value : String) : URI
  uri = URI.parse(value)
  unless {"http", "https"}.includes?(uri.scheme) && uri.host
    raise InvalidUrlError.new("Invalid URL")
  end
  uri
rescue URI::Error
  raise InvalidUrlError.new("Invalid URL")
end

def fetch(url : URI, redirects = 0) : HTTP::Client::Response
  response = HTTP::Client.get(url)
  if response.status.redirection? && response.headers.has_key?("Location") && redirects < 5
    return fetch(validate_url(resolve_url(response.headers["Location"], url)), redirects + 1)
  end
  response
end

def resolve_url(value : String, base : URI) : String
  return value if value.starts_with?("http://") || value.starts_with?("https://")
  return "#{base.scheme}:#{value}" if value.starts_with?("//")

  origin = String.build do |io|
    io << base.scheme << "://" << base.host
    io << ":" << base.port if base.port && base.port != default_port(base.scheme)
  end

  return origin + value if value.starts_with?("/")

  path = base.path.presence || "/"
  folder = path.ends_with?("/") ? path : File.dirname(path) + "/"
  origin + folder + value
end

def default_port(scheme : String?) : Int32?
  case scheme
  when "http"
    80
  when "https"
    443
  end
end

def xpath_text(doc : XML::Node, xpath : String) : String?
  doc.xpath_node(xpath).try &.content.presence
end

def get_page_meta_data(url : URI) : PageMetaData
  response = fetch(url)
  unless response.success?
    raise "HTTP error! status: #{response.status_code}"
  end

  content_type = response.headers["Content-Type"]?
  unless content_type && content_type.includes?("text/html")
    raise "Response is not HTML"
  end

  doc = XML.parse_html(response.body)
  favicon = xpath_text(doc, "//link[contains(concat(' ', normalize-space(@rel), ' '), ' icon ')]/@href")
  if favicon && !favicon.starts_with?("http")
    favicon = resolve_url(favicon, url)
    favicon = nil if favicon == "data:,"
  else
    default_favicon = resolve_url("/favicon.ico", url)
    default_response = fetch(validate_url(default_favicon))
    favicon = default_response.success? ? default_favicon : nil
  end

  PageMetaData.new(
    url: url.to_s,
    favicon: favicon,
    title: xpath_text(doc, "//title"),
    description: xpath_text(doc, "//meta[translate(@name, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') = 'description']/@content"),
    canonical: xpath_text(doc, "//link[translate(@rel, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') = 'canonical']/@href"),
  )
end

cache = Cache.new(ENV["DATA_LOCATION"]?)

server = HTTP::Server.new do |context|
  request = context.request
  response = context.response

  case request.path
  when "/health"
    response.status_code = 200
  when "/link-extract"
    url_query = request.query_params["url"]?
    unless url_query
      send_problem(response, 400, "Bad Request", "Please provide a url query parameter", "missing-query-param")
      next
    end

    begin
      url = validate_url(URI.decode_www_form(url_query))
      puts "URL\t#{url}" if ENV["VERBOSE"]? == "true"
      meta = cache.find_one(url.to_s)
      if meta
        puts "CACHED\t#{meta.canonical}" if ENV["VERBOSE"]? == "true"
      else
        meta = get_page_meta_data(url)
        cache.insert_one(meta)
        if meta.canonical && meta.canonical != meta.url
          cache.insert_one(PageMetaData.new(
            url: meta.canonical.not_nil!,
            favicon: meta.favicon,
            title: meta.title,
            description: meta.description,
            canonical: meta.canonical,
          ))
        end
        puts "FETCHED\t#{meta.canonical}" if ENV["VERBOSE"]? == "true"
      end

      response.content_type = "application/json"
      meta.to_json(response)
    rescue error : InvalidUrlError
      send_problem(response, 400, "Bad Request", "Please provide a valid url query parameter", "invalid-url")
    rescue error
      error_message = error.message || error.to_s
      puts "ERROR\t#{error_message}"
      send_problem(response, 500, "Internal Server Error", error_message, "fetch-error")
    end
  else
    response.status_code = 404
  end
end

server.bind_tcp "0.0.0.0", 8081
server.listen
