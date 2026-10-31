package main

import (
	"bytes"
	"context"
	"encoding/json"
	"html"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"github.com/Khan/genqlient/graphql"

	"frontend/src/components"
	gql "frontend/src/generated"
)

func TestBrowseSortSelection(t *testing.T) {
	for _, tc := range []struct{ query, sort, selected string }{
		{"", "", `value="" hidden selected>Automatisch: Neueste zuerst`},
		{"Apfel", "", `value="" hidden selected>Automatisch: Relevanz`},
		{"", "relevance", `value="relevance" selected>Relevanz`},
		{"", "newest", `value="newest" selected>Neueste zuerst`},
		{"Apfel", "newest", `value="newest" selected>Neueste zuerst`},
	} {
		t.Run(tc.query+"/"+tc.sort, func(t *testing.T) {
			var body bytes.Buffer
			state := components.BrowseState{Query: tc.query, Sort: tc.sort, Kind: "search", Page: 1, PerPage: 24}
			if err := components.Browse(state).Render(context.Background(), &body); err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(body.String(), tc.selected) || strings.Count(body.String(), " selected") != 1 ||
				strings.Count(body.String(), "<option ") != 8 || !strings.Contains(body.String(), `value="" hidden`) {
				t.Fatalf("explicit versus automatic selection lost: %s", body.String())
			}
		})
	}
}

func TestRecipeCardTagsAreOrderedAndCappedInServerHTML(t *testing.T) {
	var body bytes.Buffer
	state := components.BrowseState{
		Kind: "search",
		Recipes: []gql.RecipeStub{{
			Id:   "recipe",
			Name: "Eintopf",
			Tags: []gql.RecipeTag{
				{Id: "course", Category: gql.TagCategoryCourse, Name: "Hauptgericht"},
				{Id: "dietary", Category: gql.TagCategoryDietaryStyle, Name: "Vegan"},
				{Id: "cuisine", Category: gql.TagCategoryCuisine, Name: "Deutsch"},
				{Id: "dessert", Category: gql.TagCategoryCourse, Name: "Dessert"},
			},
		}},
	}
	if err := components.Browse(state).Render(context.Background(), &body); err != nil {
		t.Fatal(err)
	}
	rendered := html.UnescapeString(body.String())
	if !strings.Contains(rendered, `href="/recipe/recipe"`) ||
		!strings.Contains(rendered, `aria-label="Rezept Eintopf. Küche: Deutsch. Ernährungsweise: Vegan. Gang: Dessert. Gang: Hauptgericht"`) ||
		strings.Count(rendered, `data-recipe-tag`) != 4 ||
		!strings.Contains(rendered, `aria-label="Weitere Tags: 1"`) ||
		!strings.Contains(rendered, `>+1</span>`) {
		t.Fatalf("server-rendered tag pills or card link are incorrect: %s", rendered)
	}
}

func TestRecipeCardOmitsEmptyAndUnavailableTags(t *testing.T) {
	var body bytes.Buffer
	state := components.BrowseState{
		Kind: "search",
		Recipes: []gql.RecipeStub{
			{Id: "empty", Name: "Untaged", Tags: []gql.RecipeTag{}},
			{Id: "failed", Name: "Unavailable"},
		},
	}
	if err := components.Browse(state).Render(context.Background(), &body); err != nil {
		t.Fatal(err)
	}
	rendered := html.UnescapeString(body.String())
	if strings.Contains(rendered, "Tags nicht verfügbar") ||
		strings.Contains(rendered, `data-recipe-tag`) ||
		strings.Contains(rendered, `aria-label="Rezept Unavailable. Tags nicht verfügbar"`) ||
		!strings.Contains(rendered, `aria-label="Rezept Untaged"`) ||
		!strings.Contains(rendered, `aria-label="Rezept Unavailable"`) ||
		!strings.Contains(rendered, `data-recipe-id="empty"`) ||
		!strings.Contains(rendered, `data-recipe-id="failed"`) {
		t.Fatalf("empty and unavailable tags should both be omitted: %s", rendered)
	}
}

func TestBrowseOptions(t *testing.T) {
	for _, tc := range []struct {
		name, raw, query, token, sort string
		page                          int
	}{
		{"all", "", "*", "", "created_at:desc,recipe_id_sort:asc", 1},
		{"text", "q=++Kartoffelsuppe++", "Kartoffelsuppe", "", "_text_match:desc,created_at:desc,recipe_id_sort:asc", 1},
		{"whitespace", "q=+++", "*", "", "created_at:desc,recipe_id_sort:asc", 1},
		{"explicit relevance all", "sort=relevance", "*", "relevance", "created_at:desc,recipe_id_sort:asc", 1},
		{"explicit relevance text", "q=Apfel&sort=relevance", "Apfel", "relevance", "_text_match:desc,created_at:desc,recipe_id_sort:asc", 1},
		{"rating", "q=Apfel&sort=rating", "Apfel", "rating", "rating_average:desc,rating_count:desc,recipe_id_sort:asc", 1},
		{"rating count", "sort=rating-count", "*", "rating-count", "rating_count:desc,rating_average:desc,recipe_id_sort:asc", 1},
		{"name ascending", "sort=name-asc", "*", "name-asc", "name_sort:asc,recipe_id_sort:asc", 1},
		{"name descending", "sort=name-desc", "*", "name-desc", "name_sort:desc,recipe_id_sort:asc", 1},
		{"newest", "sort=newest", "*", "newest", "created_at:desc,recipe_id_sort:asc", 1},
		{"updated page", "sort=updated&page=3", "*", "updated", "updated_at:desc,recipe_id_sort:asc", 3},
		{"automatic form", "q=Apfel&sort=", "Apfel", "", "_text_match:desc,created_at:desc,recipe_id_sort:asc", 1},
		{"ignore raw options", "sort_by=bad&per_page=999&query_by=secret", "*", "", "created_at:desc,recipe_id_sort:asc", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			values, err := url.ParseQuery(tc.raw)
			if err != nil {
				t.Fatal(err)
			}
			request, err := parseBrowseRequest(values)
			if err != nil {
				t.Fatal(err)
			}
			var options browseOptions
			raw := request.options()
			if err := json.Unmarshal(raw, &options); err != nil {
				t.Fatal(err)
			}
			if options.Query != tc.query || options.SortBy != tc.sort || options.Page != tc.page || options.PerPage != 24 ||
				request.sort != tc.token {
				t.Fatalf("unexpected options/request: %s %+v", raw, request)
			}
			next, err := url.Parse(request.pageURL(tc.page + 1))
			if err != nil {
				t.Fatal(err)
			}
			if next.Path != "/" || next.Query().Get("sort") != tc.token || (tc.token == "" && next.Query().Has("sort")) ||
				next.Query().Get("q") == "*" {
				t.Fatalf("incorrect native pagination URL: %s", next)
			}
		})
	}
}

func TestBrowseValidation(t *testing.T) {
	for _, query := range []string{
		"sort=bogus", "sort=created_at:asc", "page=0", "page=-1", "page=nope", "page=", "page=1.5",
		"page=2147483648", "page=1&page=2", "sort=rating&sort=newest", "q=one&q=two",
	} {
		t.Run(query, func(t *testing.T) {
			calls := 0
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				t.Error("invalid request reached GraphQL")
			}))
			defer upstream.Close()
			handler := newHandler(graphql.NewClient(upstream.URL, upstream.Client()), nil)
			for _, fragment := range []bool{false, true} {
				recorder := httptest.NewRecorder()
				request := httptest.NewRequest("GET", "/?"+query, nil)
				if fragment {
					request.Header.Set("HX-Request", "true")
				}
				handler.ServeHTTP(recorder, request)
				body := recorder.Body.String()
				wantStatus := 400
				if fragment {
					wantStatus = 200
				}
				if recorder.Code != wantStatus || !strings.Contains(body, "Ungültige Suchparameter.") || strings.Contains(body, "data-recipe-id") {
					t.Fatalf("invalid request missing usable error: %d %s", recorder.Code, body)
				}
				if fragment {
					if !strings.Contains(body, `data-kind="error"`) || !strings.Contains(body, "data-browse-status") {
						t.Fatal("invalid fragment lost its existing error state")
					}
				} else if strings.Count(body, "<header-component ") != 1 ||
					strings.Count(body, "<main>") != 1 ||
					strings.Contains(body, `name="q"`) ||
					!strings.Contains(body, "<title>Ungültige Suchparameter | RezeptDB</title>") ||
					recorder.Header().Get("Content-Type") != "text/html; charset=utf-8" ||
					recorder.Header().Get("Cache-Control") != "no-store" ||
					recorder.Header().Get("ETag") != "" {
					t.Fatalf("invalid full-page error is not a styled message-only page: %s", body)
				}
			}
			if calls != 0 {
				t.Fatal("invalid input queried backend")
			}
		})
	}
}

func TestBrowseCanonicalFormURL(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct{ OperationName string }
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
		}
		var data any
		if request.OperationName == "BrowseServices" {
			data = map[string]any{"searchOnline": false, "recipeEditOnline": false, "ratingsOnline": false}
		} else {
			data = map[string]any{"recipes": []any{}}
		}
		if err := json.NewEncoder(w).Encode(map[string]any{"data": data}); err != nil {
			t.Error(err)
		}
	}))
	defer upstream.Close()
	handler := newHandler(graphql.NewClient(upstream.URL, upstream.Client()), nil)
	for _, tc := range []struct {
		path, location string
		history        bool
	}{
		{"/?q=&sort=", "/", false},
		{"/?q=+++&sort=", "/", false},
		{"/?q=++Apfel++&sort=", "/?q=Apfel", false},
		{"/?q=&sort=relevance", "/?sort=relevance", false},
		{"/?q=&sort=newest&page=2", "/?page=2&sort=newest", false},
		{"/?q=&sort=", "", true},
	} {
		t.Run(tc.path+strconv.FormatBool(tc.history), func(t *testing.T) {
			r := httptest.NewRequest("GET", tc.path, nil)
			if tc.history {
				r.Header.Set("HX-History-Restore-Request", "true")
			}
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, r)
			wantStatus := 200
			if tc.location != "" {
				wantStatus = 302
			}
			if recorder.Code != wantStatus || recorder.Header().Get("Location") != tc.location ||
				recorder.Header().Get("Cache-Control") != "no-store" {
				t.Fatalf("incorrect canonical response: %d %v", recorder.Code, recorder.Header())
			}
		})
	}
}

func TestBrowseHTTP(t *testing.T) {
	for _, tc := range []struct {
		name, kind                   string
		searchOnline, editor, rating bool
		statusError, searchError     bool
		overviewError, badMetadata   bool
		hits, page                   int
		ids                          []string
		code                         int
	}{
		{name: "online ordered short batch", kind: "search", searchOnline: true, editor: true, rating: true, hits: 49, page: 1, ids: []string{"second", "first"}, code: 200},
		{name: "empty batch with more hits", kind: "search", searchOnline: true, hits: 49, page: 2, code: 200},
		{name: "last page", kind: "search", searchOnline: true, hits: 49, page: 3, ids: []string{"last"}, code: 200},
		{name: "no results", kind: "search", searchOnline: true, editor: true, page: 1, code: 200},
		{name: "one result", kind: "search", searchOnline: true, hits: 1, page: 1, ids: []string{"only"}, code: 200},
		{name: "one result on append", kind: "search", searchOnline: true, hits: 1, page: 2, ids: []string{"only"}, code: 200},
		{name: "offline only fallback", kind: "fallback", editor: true, rating: true, page: 2, ids: []string{"unfiltered"}, code: 200},
		{name: "status failure", kind: "error", searchOnline: true, statusError: true, page: 1, code: 502},
		{name: "search failure no fallback", kind: "error", searchOnline: true, editor: true, searchError: true, page: 1, code: 502},
		{name: "later search failure", kind: "error", searchOnline: true, searchError: true, page: 2, code: 502},
		{name: "offline fallback failure", kind: "error", overviewError: true, page: 1, code: 502},
		{name: "invalid response metadata", kind: "error", searchOnline: true, badMetadata: true, page: 1, code: 502},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var operations []string
			recipes := make([]any, 0, len(tc.ids))
			for _, id := range tc.ids {
				recipes = append(recipes, map[string]any{
					"id": id, "name": "Recipe " + id,
					"rating": map[string]any{"recipeId": id, "average": 4, "count": 2},
				})
			}

			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var request struct {
					OperationName string
					Variables     map[string]json.RawMessage
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
				}
				operations = append(operations, request.OperationName)
				var data any
				var fail bool
				switch request.OperationName {
				case "BrowseServices":
					fail = tc.statusError
					data = map[string]any{"searchOnline": tc.searchOnline, "recipeEditOnline": tc.editor, "ratingsOnline": tc.rating}
				case "BrowseSearch":
					fail = tc.searchError
					var options browseOptions
					if err := json.Unmarshal(request.Variables["options"], &options); err != nil {
						t.Errorf("options must be a JSON object, not a quoted string: %s", request.Variables["options"])
					}
					if options.Query != "Apfel" || options.SortBy != browseSorts["rating"] || options.Page > tc.page || options.PerPage != 24 {
						t.Errorf("incorrect options: %+v", options)
					}
					pageSize := 24
					if tc.badMetadata {
						pageSize = 1
					}
					data = map[string]any{"searchRecipes": map[string]any{
						"recipes": recipes, "found": tc.hits, "page": options.Page, "perPage": pageSize,
					}}
				case "Overview":
					fail = tc.overviewError
					data = map[string]any{"recipes": recipes, "recipeEditOnline": tc.editor, "ratingsOnline": tc.rating}
				default:
					t.Errorf("unexpected operation: %s", request.OperationName)
				}
				response := map[string]any{"data": data}
				if fail {
					response = map[string]any{"errors": []any{map[string]any{"message": "backend unavailable", "extensions": map[string]any{"code": "not-ready"}}}}
				}
				if err := json.NewEncoder(w).Encode(response); err != nil {
					t.Error(err)
				}
			}))
			defer upstream.Close()
			handler := newHandler(graphql.NewClient(upstream.URL, upstream.Client()), nil)
			for _, mode := range []string{"native", "fragment", "boosted", "history"} {
				fragment := mode == "fragment"
				operations = nil
				query := url.Values{"q": {"Apfel"}, "sort": {"rating"}, "page": {strconv.Itoa(tc.page)}}.Encode()
				if tc.page == 1 {
					query = url.Values{"q": {"Apfel"}, "sort": {"rating"}}.Encode()
				}
				recorder := httptest.NewRecorder()
				request := httptest.NewRequest("GET", "/?"+query, nil)
				if mode != "native" {
					request.Header.Set("HX-Request", "true")
				}
				if mode == "boosted" {
					request.Header.Set("HX-Boosted", "true")
					request.Header.Set("HX-Target", "body")
				}
				if mode == "history" {
					request.Header.Set("HX-History-Restore-Request", "true")
				}
				if fragment && tc.page > 1 {
					request.Header.Set("HX-Target", "browse-pagination")
				}
				handler.ServeHTTP(recorder, request)
				body := html.UnescapeString(recorder.Body.String())
				wantCode := tc.code
				if fragment {
					wantCode = 200
				}
				pageError := fragment && tc.kind == "error" && tc.page > 1
				fullPageError := !fragment && tc.kind == "error"
				if recorder.Code != wantCode || (!pageError && !fullPageError && !strings.Contains(body, `data-kind="`+tc.kind+`"`)) ||
					recorder.Header().Get("Cache-Control") != "no-store" || recorder.Header().Get("ETag") != "" {
					t.Fatalf("incorrect browse response: %d %s", recorder.Code, body)
				}
				if pageError {
					if recorder.Header().Get("HX-Retarget") != "#browse-pagination" ||
						!strings.Contains(body, "Erneut versuchen") || strings.Contains(body, "intersect") ||
						strings.Contains(body, "data-recipe-id") || strings.Contains(body, "<title>") ||
						recorder.Header().Get("HX-Replace-Url") != "" {
						t.Fatalf("load-more error must retain cards/title/URL and stop automatic loading: %s", body)
					}
					continue
				}
				if len(operations) == 0 || operations[0] != "BrowseServices" {
					t.Fatalf("every request must first check availability: %v", operations)
				}
				wantOperations := []string{"BrowseServices"}
				if !tc.statusError {
					if tc.searchOnline {
						wantOperations = append(wantOperations, "BrowseSearch")
						if tc.kind == "search" && !fragment {
							for page := 2; page <= tc.page && (page-1)*24 < tc.hits; page++ {
								wantOperations = append(wantOperations, "BrowseSearch")
							}
						}

					} else {
						wantOperations = append(wantOperations, "Overview")
					}
				}
				if strings.Contains(body, `itemprop="aggregateRating"`) != (tc.kind != "error" && tc.rating && len(tc.ids) > 0) {
					t.Fatal("rating display not service gated")
				}
				if strings.Join(operations, ",") != strings.Join(wantOperations, ",") {
					t.Fatalf("unexpected fallback/search: %v", operations)
				}
				if strings.Contains(body, "<html") == fragment {
					t.Fatal("fragment/full page contract broken")
				}
				if !fragment {
					if strings.Count(body, "<header-component ") != 1 || strings.Count(body, "<main>") != 1 ||
						recorder.Header().Get("HX-Replace-Url") != "" {
						t.Fatalf("%s navigation must retain one shared layout without fragment headers: %s", mode, body)
					}
					if fullPageError {
						if strings.Contains(body, `id="browse-form"`) || strings.Contains(body, "data-recipe-id") ||
							!strings.Contains(body, "Rezepte konnten nicht geladen werden.") ||
							recorder.Header().Get("Content-Type") != "text/html; charset=utf-8" {
							t.Fatalf("%s error must be message-only HTML: %s", mode, body)
						}
						wantMarker := mode == "boosted" || mode == "history"
						if (recorder.Header().Get("X-Browse-Full-Page-Error") == "true") != wantMarker {
							t.Fatalf("%s navigation has incorrect HTMX error marker", mode)
						}
						if wantMarker {
							if recorder.Header().Get("HX-Retarget") != "main" ||
								recorder.Header().Get("HX-Reswap") != "innerHTML" ||
								recorder.Header().Get("HX-Reselect") != "main > *" {
								t.Fatalf("%s navigation must only swap the error content: %v", mode, recorder.Header())
							}
						} else if recorder.Header().Get("HX-Retarget") != "" ||
							recorder.Header().Get("HX-Reswap") != "" || recorder.Header().Get("HX-Reselect") != "" {
							t.Fatalf("%s direct error unexpectedly has fragment headers: %v", mode, recorder.Header())
						}
					} else if !strings.Contains(body, `id="browse-form"`) {
						t.Fatalf("%s successful navigation lost the search form: %s", mode, body)
					}
				}
				if tc.kind == "error" {
					if !strings.Contains(body, "Rezepte konnten nicht geladen werden.") || strings.Contains(body, "data-recipe-id") {
						t.Fatal("error must remove previous-query cards")
					}
				} else {
					position := -1
					for _, id := range tc.ids {
						next := strings.Index(body, `data-recipe-id="`+id+`"`)
						if next <= position {
							t.Fatal("recipe ordering/identity lost")
						}
						position = next
					}
				}
				if tc.kind == "fallback" && (!strings.Contains(body, "Suche nicht verfügbar. Alle Rezepte werden angezeigt.") ||
					strings.Count(body, " disabled") != 3) {
					t.Fatal("fallback must warn and disable controls")
				}
				more := tc.kind == "search" && tc.page*24 < tc.hits
				if strings.Contains(body, " data-load-more") != more || strings.Contains(body, " data-sentinel") != more {
					t.Fatal("pagination used card count instead of API metadata")
				}
				if more && !strings.Contains(body, `href="/?page=`+strconv.Itoa(tc.page+1)+`&q=Apfel&sort=rating"`) {
					t.Fatalf("missing ordinary GET pagination: %s", body)
				}
				if strings.Contains(body, "data-add-recipe") {
					t.Fatal("privileged add affordance must remain in the dynamic controls fragment")
				}
				if tc.kind == "search" && tc.hits == 0 && !strings.Contains(body, "Keine Rezepte gefunden.") {
					t.Fatal("empty successful search not distinguished")
				}
				if !fragment && !fullPageError && (!strings.Contains(body, `value="Apfel"`) || !strings.Contains(body, `value="rating" selected`) ||
					!strings.Contains(body, `id="browse-heading"`) || !strings.Contains(body, "header-component")) {
					t.Fatal("full replacement did not retain controls/header")
				}
				wantTitle := "Alle Rezepte | RezeptDB"
				if tc.kind == "search" {
					noun := "Rezepte"
					if tc.hits == 1 {
						noun = "Rezept"
						if !strings.Contains(body, "1 Rezept gefunden.") || strings.Contains(body, "1 Rezepte") {
							t.Fatalf("incorrect singular result count: %s", body)
						}
					}
					heading := strconv.Itoa(tc.hits) + " " + noun + " für 'Apfel'"
					if !strings.Contains(body, ">"+heading+"</h1>") {
						t.Fatalf("incorrect query-aware heading: %s", body)
					}
					wantTitle = heading + " | RezeptDB"
				} else if tc.kind == "error" {
					wantTitle = "Rezepte konnten nicht geladen werden | RezeptDB"
				}
				if !strings.Contains(body, "<title>"+wantTitle+"</title>") {
					t.Fatalf("incorrect query-aware title: %s", body)
				}
			}
		})
	}
}

func TestBrowseKeepsCardsOnPartialTagErrors(t *testing.T) {
	for _, searchOnline := range []bool{false, true} {
		name := "overview"
		wantKind := "fallback"
		if searchOnline {
			name, wantKind = "search", "search"
		}
		t.Run(name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var request struct{ OperationName string }
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
				}
				var response map[string]any
				switch request.OperationName {
				case "BrowseServices":
					response = map[string]any{"data": map[string]any{
						"searchOnline": searchOnline, "ratingsOnline": false,
					}}
				case "BrowseSearch", "Overview":
					recipes := []any{
						map[string]any{"id": "empty", "name": "Empty", "tags": []any{}},
						map[string]any{"id": "failed", "name": "Failed", "tags": nil},
					}
					if request.OperationName == "BrowseSearch" {
						response = map[string]any{"data": map[string]any{
							"searchRecipes": map[string]any{
								"recipes": recipes, "found": 2, "page": 1, "perPage": 24,
							},
						}}
						response["errors"] = []any{map[string]any{
							"message": "tags unavailable",
							"path":    []any{"searchRecipes", "recipes", 1, "tags"},
							"extensions": map[string]any{
								"code": "service-unavailable", "status": 503, "service": "tags",
							},
						}}
					} else {
						response = map[string]any{"data": map[string]any{
							"recipes": recipes, "ratingsOnline": false,
						}}
						response["errors"] = []any{map[string]any{
							"message": "tags unavailable",
							"path":    []any{"recipes", 1, "tags"},
							"extensions": map[string]any{
								"code": "service-unavailable", "status": 503, "service": "tags",
							},
						}}
					}
				default:
					t.Errorf("unexpected operation: %s", request.OperationName)
				}
				if err := json.NewEncoder(w).Encode(response); err != nil {
					t.Error(err)
				}
			}))
			defer upstream.Close()
			handler := newHandler(graphql.NewClient(upstream.URL, upstream.Client()), nil)
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, httptest.NewRequest("GET", "/", nil))
			body := html.UnescapeString(response.Body.String())
			if response.Code != http.StatusOK || strings.Count(body, `data-recipe-id=`) != 2 ||
				strings.Contains(body, "Tags nicht verfügbar") ||
				!strings.Contains(body, `data-recipe-id="empty"`) ||
				!strings.Contains(body, `aria-label="Rezept Failed"`) ||
				!strings.Contains(body, `data-kind="`+wantKind+`"`) {
				t.Fatalf("partial tag failure discarded recipe cards: %d %s", response.Code, body)
			}
		})
	}
}
