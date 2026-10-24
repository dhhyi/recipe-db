package main

import (
	"bytes"
	"context"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/a-h/templ"

	"frontend/src/components"
)

func TestBrowseSearchAsset(t *testing.T) {
	handler := newHandler(nil, nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest("GET", "/browse/search.js", nil))
	if response.Code != 200 || response.Header().Get("Content-Type") != "text/javascript; charset=utf-8" {
		t.Fatalf("unexpected asset response: %d %v", response.Code, response.Header())
	}
	if !bytes.Equal(response.Body.Bytes(), browseSearchJS) ||
		!strings.Contains(response.Body.String(), `document.querySelector("[data-browse-search]")`) ||
		strings.Contains(response.Body.String(), "customElements.define") {
		t.Fatal("browse asset must serve the embedded, standalone listing controller")
	}
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest("GET", "/browse/unknown.js", nil))
	if response.Code != 404 {
		t.Fatalf("unknown browse asset returned %d", response.Code)
	}
}

func TestBrowseSearchOnlyLoadedOnListing(t *testing.T) {
	for _, tc := range []struct {
		name      string
		component templ.Component
		search    bool
	}{
		{"listing", components.Browse(components.BrowseState{Kind: "search", Page: 1, PerPage: 24}), true},
		{"results fragment", components.BrowseResults(components.BrowseState{}, true), false},
		{"layout", components.Layout("Recipe"), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var output bytes.Buffer
			if err := tc.component.Render(context.Background(), &output); err != nil {
				t.Fatal(err)
			}
			body := output.String()
			if strings.Contains(body, `<script type="module" src="/browse/search.js"></script>`) != tc.search ||
				strings.Contains(body, "<div data-browse-search>") != tc.search ||
				strings.Contains(body, "<browse-search") {
				t.Fatalf("incorrect listing enhancement ownership: %s", body)
			}
		})
	}
}
