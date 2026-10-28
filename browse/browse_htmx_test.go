package main

import (
	"bytes"
	"context"
	"encoding/json"
	"html"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/Khan/genqlient/graphql"
	"github.com/a-h/templ"

	"frontend/src/components"
)

func TestBrowseHeadingsAndCounts(t *testing.T) {
	for _, tc := range []struct {
		name, kind, query, heading, status string
		found                              int
	}{
		{"singular", "search", "milch", "1 Rezept für 'milch'", "1 Rezept gefunden.", 1},
		{"plural", "search", "milch", "2 Rezepte für 'milch'", "2 Rezepte gefunden.", 2},
		{"zero", "search", "milch", "0 Rezepte für 'milch'", "Keine Rezepte gefunden.", 0},
		{"unfiltered", "search", "", "Alle Rezepte", "1 Rezept gefunden.", 1},
		{"fallback", "fallback", "milch", "Alle Rezepte", "1 Rezept gefunden.", 1},
		{"escaped query", "search", "<milch>&", "1 Rezept für '<milch>&'", "1 Rezept gefunden.", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := components.BrowseState{Kind: tc.kind, Query: tc.query, Found: tc.found}
			if got := state.Title(); got != tc.heading+" | RezeptDB" {
				t.Fatalf("unexpected title: %s", got)
			}
			for _, mode := range []struct {
				name      string
				component templ.Component
				oob       bool
			}{
				{"full", components.Browse(state), false},
				{"search", components.BrowseFragment(state), true},
				{"pagination", components.BrowsePage(state), true},
				{"fallback", components.BrowseFallbackFragment(state), false},
			} {
				t.Run(mode.name, func(t *testing.T) {
					var body bytes.Buffer
					if err := mode.component.Render(context.Background(), &body); err != nil {
						t.Fatal(err)
					}
					rendered := html.UnescapeString(body.String())
					heading := `<h1 id="browse-heading"`
					if mode.oob {
						heading += ` hx-swap-oob="outerHTML"`
					}
					heading += `>` + tc.heading + `</h1>`
					if strings.Count(rendered, "<h1 ") != 1 || !strings.Contains(rendered, heading) ||
						!strings.Contains(rendered, tc.status) {
						t.Fatalf("heading or result count missing: %s", rendered)
					}
					if mode.name != "full" && !strings.Contains(rendered, "<title>"+state.Title()+"</title>") {
						t.Fatalf("fragment title missing: %s", rendered)
					}
					if tc.name == "escaped query" && strings.Contains(body.String(), "<milch>") {
						t.Fatal("search query must be HTML escaped")
					}
				})
			}
		})
	}
}

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
			ids := []string{"c", "d"}
			if options.Page < 3 {
				ids = [][]string{{"a", "b"}, {"b", "c"}}[options.Page-1]
			}
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
	for _, mode := range []string{"native", "fragment", "history", "append", "deep-history", "deep-append"} {
		t.Run(mode, func(t *testing.T) {
			pages = nil
			page := 3
			if strings.HasPrefix(mode, "deep-") {
				page = browseRestorePageLimit + 1
			}
			pageToken := strconv.Itoa(page)
			request := httptest.NewRequest("GET", "/?page="+pageToken+"&q=Apfel", nil)
			if mode != "native" {
				request.Header.Set("HX-Request", "true")
			}
			if mode == "history" || mode == "deep-history" {
				request.Header.Set("HX-History-Restore-Request", "true")
			}
			if strings.HasSuffix(mode, "append") {
				request.Header.Set("HX-Target", "browse-pagination")
				request.URL.RawQuery += "&seen=a&seen=b&seen=c"
			}
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			body := html.UnescapeString(response.Body.String())
			if mode == "deep-history" {
				if response.Code != 200 || len(pages) != 1 || pages[0] != page ||
					strings.Count(body, "data-recipe-id=") != 2 || !strings.Contains(body, "<html") ||
					!strings.Contains(body, "Es wird nur die aktuelle Ergebnisseite angezeigt.") ||
					!strings.Contains(body, `data-page="`+pageToken+`"`) {
					t.Fatalf("deep history must remain bounded and disclose current-page restoration: pages=%v %s", pages, body)
				}
				return
			}
			if strings.HasSuffix(mode, "append") {
				if response.Code != 200 || len(pages) != 1 || pages[0] != page ||
					strings.Count(body, "data-recipe-id=") != 1 || !strings.Contains(body, `data-recipe-id="d"`) ||
					strings.Contains(body, "data-add-recipe") || strings.Contains(body, `<section`) ||
					!strings.Contains(body, `hx-swap-oob="outerHTML"`) ||
					!strings.Contains(body, "49 Rezepte gefunden. Alle Rezepte geladen.") ||
					!strings.Contains(body, `data-page="`+pageToken+`" data-per-page="24" data-found="49"`) ||
					response.Header().Get("HX-Replace-Url") != "/?page="+pageToken+"&q=Apfel" {
					t.Fatalf("append must query only the next page and leave existing cards intact: pages=%v %s", pages, body)
				}
				return
			}
			if response.Code != 200 || len(pages) != 3 || pages[0] != 1 || pages[1] != 2 || pages[2] != 3 ||
				strings.Count(body, "data-recipe-id=") != 4 || strings.Contains(body, "data-add-recipe") ||
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
		`hx-on::config-request=`,
		`hx-on::send-error=`, `hx-on::response-error=`, `hx-on:browse-error=`,
		`hx-sync="this:replace"`, `hx-sync="#browse-form:abort"`,
		`hx-trigger="intersect once, click"`, `href="/?page=2"`,
		`hx-target="#browse-pagination"`,
		`col-span-full order-1`,
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
