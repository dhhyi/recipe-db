require "airborne"
require "base64"
require "cgi"
require "json"
require "net/http"
require "uri"

RSpec.describe "image-inline" do
  before(:all) do
    Airborne.configure do |config|
      config.base_url = ENV.fetch("REST_API")
    end

    fixture = URI("#{ENV.fetch("FIXTURE_API")}/tiny.png")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    loop do
      response = Net::HTTP.get_response(fixture)
      break if response.is_a?(Net::HTTPSuccess)
      raise "Fixture #{fixture} returned HTTP #{response.code}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.2
    end
  end

  let(:fixture_api) { ENV.fetch("FIXTURE_API") }

  it "probes availability without fetching an image" do
    head "/image-inline/"
    expect_status(204)
    expect(response.body).to be_empty
  end

  def inline_path(url)
    "/image-inline/?url=#{CGI.escape(url)}"
  end

  def expect_problem(status, title, code)
    expect_status(status)
    expect_header("content_type", "application/problem+json")
    problem = JSON.parse(response.body)
    expect(problem.keys).to contain_exactly("type", "title", "status", "detail", "code")
    expect(problem).to include("type" => "about:blank", "title" => title, "status" => status, "code" => code)
    expect(problem.fetch("detail")).to be_a(String)
    expect(problem.fetch("detail")).not_to be_empty
    problem
  end

  it "rejects a request missing the url parameter" do
    get "/image-inline/"
    problem = expect_problem(400, "Bad Request", "missing-query-param")
    expect(problem.fetch("detail")).to eq("Missing url parameter")
  end

  it "inlines a PNG fixture as a base64 data URI" do
    get inline_path("#{fixture_api}/tiny.png")
    expect_status(200)
    expect_header("content_type", "text/plain")
    expect(response.body).to start_with("data:image/png;base64,")

    encoded = response.body.sub("data:image/png;base64,", "")
    expect(Base64.decode64(encoded)).to eq(File.read("fixtures/tiny.png", mode: "rb"))
  end

  it "inlines a JPEG fixture as a base64 data URI" do
    get inline_path("#{fixture_api}/tiny.jpg")
    expect_status(200)

    encoded = response.body.sub("data:image/jpeg;base64,", "")
    expect(Base64.decode64(encoded)).to eq(File.read("fixtures/tiny.jpg", mode: "rb"))
  end

  it "reports a fetch error for an upstream 404" do
    get inline_path("#{fixture_api}/does-not-exist.png")
    problem = expect_problem(500, "Internal Server Error", "fetch-error")
    expect(problem.fetch("detail")).to include("404")
  end

  it "reports a fetch error when the upstream connection fails" do
    get inline_path("http://127.0.0.1:1/unreachable.png")
    problem = expect_problem(500, "Internal Server Error", "fetch-error")
    expect(problem.fetch("detail")).to include("ConnectionFailure")
  end
end
