package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSameOriginRequestRequiresExactBrowserOrigin(t *testing.T) {
	for _, testCase := range []struct {
		name    string
		origin  string
		host    string
		proto   string
		headers []string
		want    bool
	}{
		{name: "same origin", origin: "https://recipes.example", host: "recipes.example", proto: "https", want: true},
		{name: "default port", origin: "https://recipes.example", host: "recipes.example:443", proto: "https", want: true},
		{name: "wrong host", origin: "https://attacker.example", host: "recipes.example", proto: "https"},
		{name: "wrong scheme", origin: "http://recipes.example", host: "recipes.example", proto: "https"},
		{name: "missing origin", host: "recipes.example", proto: "https"},
		{name: "duplicate origin", origin: "https://recipes.example", host: "recipes.example", proto: "https", headers: []string{"https://attacker.example"}},
		{name: "spoofed proxy scheme", origin: "https://recipes.example", host: "recipes.example", proto: "https,http"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "http://"+testCase.host+"/recipe/42/rate", nil)
			request.Host = testCase.host
			if testCase.origin != "" {
				request.Header.Add("Origin", testCase.origin)
			}
			for _, value := range testCase.headers {
				request.Header.Add("Origin", value)
			}
			if testCase.proto != "" {
				request.Header.Set("X-Forwarded-Proto", testCase.proto)
			}
			if got := sameOriginRequest(request); got != testCase.want {
				t.Fatalf("sameOriginRequest() = %v, want %v", got, testCase.want)
			}
		})
	}
}

func TestRequestTransportForwardsOnlyTrustedIdentityAndRelaysCookies(t *testing.T) {
	for _, testCase := range []struct {
		name       string
		headers    http.Header
		wantAuth   string
		wantCookie string
	}{
		{
			name: "session cookie allowlist",
			headers: http.Header{
				"Cookie": []string{"other=secret; _oauth2_proxy=session; _oauth2_proxy_0=chunk"},
			},
			wantCookie: "_oauth2_proxy=session; _oauth2_proxy_0=chunk",
		},
		{
			name: "bearer takes precedence",
			headers: http.Header{
				"Authorization": []string{"token-id"},
				"Cookie":        []string{"_oauth2_proxy=session"},
			},
			wantAuth: "token-id",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			writer := httptest.NewRecorder()
			transport := requestTransport{
				headers: testCase.headers,
				writer:  writer,
				next: roundTripFunc(func(request *http.Request) (*http.Response, error) {
					if got := request.Header.Get("Authorization"); got != testCase.wantAuth {
						t.Errorf("forwarded Authorization = %q, want %q", got, testCase.wantAuth)
					}
					if got := request.Header.Get("Cookie"); got != testCase.wantCookie {
						t.Errorf("forwarded Cookie = %q, want %q", got, testCase.wantCookie)
					}
					if got := request.Header.Get("Origin"); got != "http://traefik" {
						t.Errorf("forwarded Origin = %q", got)
					}
					return &http.Response{
						StatusCode: http.StatusUnauthorized,
						Header:     http.Header{"Set-Cookie": []string{"_oauth2_proxy=; Max-Age=0"}},
						Body:       io.NopCloser(strings.NewReader("denied")),
						Request:    request,
					}, nil
				}),
			}
			request := httptest.NewRequest(http.MethodPost, "http://traefik/graphql", nil)
			response, err := transport.RoundTrip(request)
			if err != nil {
				t.Fatal(err)
			}
			response.Body.Close()
			if got := writer.Header().Values("Set-Cookie"); len(got) != 1 || got[0] != "_oauth2_proxy=; Max-Age=0" {
				t.Fatalf("Set-Cookie was not relayed: %v", got)
			}
		})
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (roundTrip roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return roundTrip(request)
}
