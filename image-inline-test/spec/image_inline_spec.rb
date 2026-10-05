require "airborne"
require "base64"
require "cgi"
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

  def inline_path(url)
    "/image-inline/?url=#{CGI.escape(url)}"
  end

  it "rejects a request missing the url parameter" do
    get "/image-inline/"
    expect_status(400)
    expect_json(code: "missing-query-param")
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

  it "reports a fetch error for an unreachable url" do
    get inline_path("#{fixture_api}/does-not-exist.png")
    expect_status(500)
    expect_json(code: "fetch-error")
  end
end
