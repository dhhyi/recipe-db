package main

import (
	"bytes"
	"context"
	"encoding/json"
	"html"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Khan/genqlient/graphql"

	"frontend/src/components"
)

func TestBrowseCumulativeHistory(t *testing.T) {
	var pages []int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			OperationName string
			Variables     map[string]json.RawMessage
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
		}
		data := map[string]any{"searchOnline": true, "recipeEditOnline": true, "ratingsOnline": false}
		if request.OperationName == "BrowseSearch" {
			var options browseOptions
			if err := json.Unmarshal(request.Variables["options"], &options); err != nil {
				t.Error(err)
			}
			pages = append(pages, options.Page)
			ids := [][]string{{"a", "b"}, {"b", "c"}, {"c", "d"}}[options.Page-1]
			var recipes []any
			for _, id := range ids {
				recipes = append(recipes, map[string]any{"id": id, "name": id})
			}
			data = map[string]any{"searchRecipes": map[string]any{
				"recipes": recipes, "found": 49, "page": options.Page, "perPage": 24,
			}}
		}
		if err := json.NewEncoder(w).Encode(map[string]any{"data": data}); err != nil {
			t.Error(err)
		}
	}))
	defer upstream.Close()
	handler := newHandler(graphql.NewClient(upstream.URL, upstream.Client()), nil)
	for _, mode := range []string{"native", "fragment", "history"} {
		t.Run(mode, func(t *testing.T) {
			pages = nil
			request := httptest.NewRequest("GET", "/?page=3&q=Apfel", nil)
			if mode != "native" {
				request.Header.Set("HX-Request", "true")
			}
			if mode == "history" {
				request.Header.Set("HX-History-Restore-Request", "true")
			}
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			body := html.UnescapeString(response.Body.String())
			if response.Code != 200 || len(pages) != 3 || pages[0] != 1 || pages[1] != 2 || pages[2] != 3 ||
				strings.Count(body, "data-recipe-id=") != 4 || strings.Count(body, "data-add-recipe") != 1 ||
				!strings.Contains(body, `data-page="3" data-per-page="24" data-found="49"`) ||
				!strings.Contains(body, "<title>49 Rezepte für 'Apfel' | RezeptDB</title>") {
				t.Fatalf("cumulative deduplicated depth not restored: pages=%v response=%d %s", pages, response.Code, body)
			}
			if mode == "fragment" {
				if strings.Contains(body, "<html") || strings.Contains(body, "<form") ||
					response.Header().Get("HX-Replace-Url") != "/?page=3&q=Apfel" {
					t.Fatalf("fragment must preserve the live form and canonical depth: %s", body)
				}
			} else if !strings.Contains(body, "<html") || !strings.Contains(body, `value="Apfel"`) {
				t.Fatalf("native/history response must contain a complete page: %s", body)
			}
		})
	}
}

func TestBrowseHTMXContract(t *testing.T) {
	var body bytes.Buffer
	if err := components.Browse(components.BrowseState{
		Kind: "search", Page: 1, PerPage: 24, NextURL: "/?page=2",
	}).Render(context.Background(), &body); err != nil {
		t.Fatal(err)
	}
	for _, attribute := range []string{
		`id="browse-query"`, `hx-get="/"`, `hx-target="#browse-results"`,
		`delay:300ms`, `compositionend`, `event.isComposing`, `htmx:abort`,
		`hx-sync="this:replace"`, `hx-sync="#browse-form:abort"`,
		`hx-trigger="intersect once, click"`, `href="/?page=2"`,
	} {
		if !strings.Contains(html.UnescapeString(body.String()), attribute) {
			t.Errorf("missing HTMX contract: %s", attribute)
		}
	}
	if strings.Contains(body.String(), "<script") {
		t.Fatal("listing must not load a custom client controller")
	}
	for _, path := range []string{"/browse/search.js", "/browse/results"} {
		response := httptest.NewRecorder()
		newHandler(nil, nil).ServeHTTP(response, httptest.NewRequest("GET", path, nil))
		if response.Code != http.StatusNotFound {
			t.Errorf("obsolete route %s returned %d", path, response.Code)
		}
	}
}
