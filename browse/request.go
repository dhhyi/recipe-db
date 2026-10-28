package main

import (
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/Khan/genqlient/graphql"
)

func sameOriginRequest(request *http.Request) bool {
	values := request.Header.Values("Origin")
	if len(values) != 1 {
		return false
	}
	origin, err := url.Parse(values[0])
	if err != nil || origin.User != nil || origin.Path != "" || origin.RawQuery != "" ||
		origin.Fragment != "" || origin.Hostname() == "" {
		return false
	}
	proto := request.Header.Values("X-Forwarded-Proto")
	if len(proto) > 1 {
		return false
	}
	scheme := ""
	if len(proto) == 1 {
		scheme = proto[0]
	}
	if scheme == "" {
		if request.TLS != nil {
			scheme = "https"
		} else {
			scheme = "http"
		}
	}
	if !strings.EqualFold(scheme, "http") && !strings.EqualFold(scheme, "https") {
		return false
	}
	if !strings.EqualFold(origin.Scheme, scheme) {
		return false
	}
	requestOrigin, err := url.Parse("//" + request.Host)
	if err != nil || requestOrigin.User != nil || requestOrigin.Hostname() == "" ||
		!strings.EqualFold(origin.Hostname(), requestOrigin.Hostname()) {
		return false
	}
	originPort, requestPort := origin.Port(), requestOrigin.Port()
	if originPort == "" {
		originPort = defaultPort(origin.Scheme)
	}
	if requestPort == "" {
		requestPort = defaultPort(scheme)
	}
	return originPort == requestPort
}

func defaultPort(scheme string) string {
	if strings.EqualFold(scheme, "https") {
		return "443"
	}
	if strings.EqualFold(scheme, "http") {
		return "80"
	}
	return ""
}

func oauthCookie(name string) bool {
	if name == "_oauth2_proxy" {
		return true
	}
	const prefix = "_oauth2_proxy_"
	if !strings.HasPrefix(name, prefix) {
		return false
	}
	_, err := strconv.Atoi(strings.TrimPrefix(name, prefix))
	return err == nil
}

type requestTransport struct {
	next    http.RoundTripper
	headers http.Header
	writer  http.ResponseWriter
	status  *int
}

func (transport requestTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	request = request.Clone(request.Context())
	request.Header = request.Header.Clone()
	if values, present := transport.headers[http.CanonicalHeaderKey("Authorization")]; present {
		for _, value := range values {
			request.Header.Add("Authorization", value)
		}
	} else {
		cookies := make([]string, 0)
		for _, cookie := range transport.headers.Values("Cookie") {
			for _, part := range strings.Split(cookie, ";") {
				name, value, found := strings.Cut(strings.TrimSpace(part), "=")
				if found && oauthCookie(name) {
					cookies = append(cookies, name+"="+value)
				}
			}
		}
		if len(cookies) > 0 {
			request.Header.Set("Cookie", strings.Join(cookies, "; "))
		}
	}
	request.Header.Set("Origin", "http://traefik")

	next := transport.next
	if next == nil {
		next = http.DefaultTransport
	}
	response, err := next.RoundTrip(request)
	if response != nil {
		if transport.status != nil {
			*transport.status = response.StatusCode
		}
		for _, cookie := range response.Header.Values("Set-Cookie") {
			transport.writer.Header().Add("Set-Cookie", cookie)
		}
	}
	return response, err
}

func requestScopedClient(endpoint string, request *http.Request, writer http.ResponseWriter) (graphql.Client, *int) {
	status := 0
	client := graphql.NewClient(endpoint, &http.Client{
		Timeout:   10 * time.Second,
		Transport: requestTransport{headers: request.Header.Clone(), writer: writer, status: &status},
	})
	return client, &status
}
