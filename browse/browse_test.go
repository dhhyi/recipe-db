package main

import (
	"bytes"
	"context"
	"encoding/json"
	"html"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/Khan/genqlient/graphql"

	"frontend/src/components"
	gql "frontend/src/generated"
)

func TestBrowseSortSelection(t *testing.T) {
	for _, tc := range []struct {
		query, sortBy, selected string
		options                 int
	}{
		{"", "", `value="" selected>Automatisch</option>`, 8},
		{"Apfel", "", `value="" selected>Automatisch</option>`, 8},
		{"", "_text_match:desc,created_at:desc,recipe_id_sort:asc", `value="_text_match:desc,created_at:desc,recipe_id_sort:asc" selected>Relevanz`, 8},
		{"", "created_at:desc,recipe_id_sort:asc", `value="created_at:desc,recipe_id_sort:asc" selected>Neueste zuerst`, 8},
		{"Apfel", "created_at:desc,recipe_id_sort:asc", `value="created_at:desc,recipe_id_sort:asc" selected>Neueste zuerst`, 8},
		{"", "rating_average:desc,_text_match:desc,recipe_id_sort:asc", `value="rating_average:desc,_text_match:desc,recipe_id_sort:asc" selected>Benutzerdefinierte Sortierung`, 9},
	} {
		t.Run(tc.query+"/"+tc.sortBy, func(t *testing.T) {
			var body bytes.Buffer
			state := components.BrowseState{Query: tc.query, SortBy: tc.sortBy, Kind: "search", Page: 1, PerPage: 24}
			if err := components.Browse(state).Render(context.Background(), &body); err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(body.String(), tc.selected) || strings.Count(body.String(), " selected") != 1 ||
				strings.Count(body.String(), "<option ") != tc.options || !strings.Contains(body.String(), `name="sort_by"`) ||
				strings.Contains(body.String(), `name="sort"`) || strings.Contains(body.String(), `>Automatisch: `) {
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
	if !strings.Contains(rendered, `<a href="/recipe/recipe" slot="title"`) ||
		!strings.Contains(rendered, `aria-label="Rezept Eintopf. Küche: Deutsch. Ernährungsweise: Vegan. Gang: Dessert. Gang: Hauptgericht"`) ||
		strings.Count(rendered, `data-recipe-tag`) != 4 ||
		!strings.Contains(rendered, `href="/?filter_by=tag_ids%3A%3D%22cuisine%22"`) ||
		!strings.Contains(rendered, `aria-label="Weitere Tags: 1"`) ||
		!strings.Contains(rendered, `>+1</a>`) ||
		strings.Contains(rendered, `<a href="/recipe/recipe" aria-label=`) {
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
		name, raw, query, sortBy, filterBy string
		sortByPresent, filterByPresent     bool
		page                               int
	}{
		{"all", "", "*", "", "", false, false, 1},
		{"text", "q=++Kartoffelsuppe++", "Kartoffelsuppe", "", "", false, false, 1},
		{"whitespace", "q=+++", "*", "", "", false, false, 1},
		{"automatic omitted", "q=Apfel&sort_by=", "Apfel", "", "", false, false, 1},
		{"explicit relevance all", "sort_by=_text_match%3Adesc%2Ccreated_at%3Adesc%2Crecipe_id_sort%3Aasc", "*", "_text_match:desc,created_at:desc,recipe_id_sort:asc", "", true, false, 1},
		{"explicit relevance text", "q=Apfel&sort_by=_text_match%3Adesc%2Ccreated_at%3Adesc%2Crecipe_id_sort%3Aasc", "Apfel", "_text_match:desc,created_at:desc,recipe_id_sort:asc", "", true, false, 1},
		{"rating", "q=Apfel&sort_by=rating_average%3Adesc%2Crating_count%3Adesc%2Crecipe_id_sort%3Aasc", "Apfel", "rating_average:desc,rating_count:desc,recipe_id_sort:asc", "", true, false, 1},
		{"rating count", "sort_by=rating_count%3Adesc%2Crating_average%3Adesc%2Crecipe_id_sort%3Aasc", "*", "rating_count:desc,rating_average:desc,recipe_id_sort:asc", "", true, false, 1},
		{"name ascending", "sort_by=name_sort%3Aasc%2Crecipe_id_sort%3Aasc", "*", "name_sort:asc,recipe_id_sort:asc", "", true, false, 1},
		{"name descending", "sort_by=name_sort%3Adesc%2Crecipe_id_sort%3Aasc", "*", "name_sort:desc,recipe_id_sort:asc", "", true, false, 1},
		{"newest", "sort_by=created_at%3Adesc%2Crecipe_id_sort%3Aasc", "*", "created_at:desc,recipe_id_sort:asc", "", true, false, 1},
		{"updated page", "sort_by=updated_at%3Adesc%2Crecipe_id_sort%3Aasc&page=3", "*", "updated_at:desc,recipe_id_sort:asc", "", true, false, 3},
		{"custom expression", "sort_by=rating_average%3Adesc%2C_text_match%3Adesc%2Crecipe_id_sort%3Aasc", "*", "rating_average:desc,_text_match:desc,recipe_id_sort:asc", "", true, false, 1},
		{"legacy token ignored", "sort=rating", "*", "", "", false, false, 1},
		{"tag filter", "filter_by=tag_ids%3A%3D%22tag%2F%2B%26%3F%22", "*", "", `tag_ids:="tag/+&?"`, false, true, 1},
		{"combined filter", "filter_by=category%3A%3D%22main%20course%22%20%26%26%20tag_ids%3A%3D%22tag%22&q=Apfel", "Apfel", "", `category:="main course" && tag_ids:="tag"`, false, true, 1},
		{"empty filter", "filter_by=", "*", "", "", false, true, 1},
		{"ignore other raw options", "per_page=999&query_by=secret", "*", "", "", false, false, 1},
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
			var fields map[string]json.RawMessage
			if err := json.Unmarshal(raw, &fields); err != nil {
				t.Fatal(err)
			}
			if options.Query != tc.query || options.SortBy != tc.sortBy || options.Page != tc.page || options.PerPage != 24 ||
				tc.sortByPresent != (fields["sort_by"] != nil) || request.sortBy != tc.sortBy {
				t.Fatalf("unexpected options/request: %s %+v", raw, request)
			}
			if tc.filterByPresent != (options.FilterBy != nil) ||
				options.FilterBy != nil && *options.FilterBy != tc.filterBy ||
				request.filterBy != tc.filterBy || request.filterByPresent != tc.filterByPresent {
				t.Fatalf("filter_by was not preserved: %s %+v", raw, request)
			}
			next, err := url.Parse(request.pageURL(tc.page + 1))
			if err != nil {
				t.Fatal(err)
			}
			if next.Path != "/" || next.Query().Get("sort_by") != tc.sortBy || (!tc.sortByPresent && next.Query().Has("sort_by")) ||
				next.Query().Get("q") == "*" || next.Query().Get("filter_by") != tc.filterBy ||
				next.Query().Has("filter_by") != tc.filterByPresent {
				t.Fatalf("incorrect native pagination URL: %s", next)
			}
		})
	}
}

func TestBrowseFilterHeadingsAndControls(t *testing.T) {
	for _, testCase := range []struct {
		name, query, filterBy, tagName, heading string
	}{
		{"single tag", "", `tag_ids:="tag-id"`, "Vegan", "Suchergebnisse für Tag „Vegan“"},
		{"generic filter", "", `category:="main course"`, "", "Gefilterte Suchergebnisse"},
		{"combined query", "Apfel", `tag_ids:="tag-id"`, "", "1 Rezept für 'Apfel'"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			state := components.BrowseState{
				Kind: "search", Query: testCase.query, FilterBy: testCase.filterBy,
				FilterByPresent: true, TagName: testCase.tagName, Found: 1,
			}
			if got := state.Heading(); got != testCase.heading {
				t.Fatalf("unexpected heading: %q", got)
			}
			var body bytes.Buffer
			if err := components.Browse(state).Render(context.Background(), &body); err != nil {
				t.Fatal(err)
			}
			rendered := html.UnescapeString(body.String())
			if !strings.Contains(rendered, `name="filter_by" value="`+testCase.filterBy+`"`) ||
				!strings.Contains(rendered, `hx-on:input="this.form.elements.namedItem('filter_by')?.remove()"`) {
				t.Fatalf("filtered controls were not rendered: %s", rendered)
			}
			if !strings.Contains(rendered, `name="q"`) ||
				!strings.Contains(rendered, `value="`+testCase.query+`"`) {
				t.Fatalf("search query was not restored: %s", rendered)
			}
		})
	}
}

func TestBrowseValidation(t *testing.T) {
	for _, query := range []string{
		"page=0", "page=-1", "page=nope", "page=", "page=1.5",
		"page=2147483648", "page=1&page=2", "sort_by=one&sort_by=two", "q=one&q=two",
		"filter_by=tag_ids%3A%3Dtag&filter_by=tag_ids%3A%3Dother",
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
		{"/?q=&sort_by=", "/", false},
		{"/?q=+++", "/", false},
		{"/?q=++Apfel++&sort_by=", "/?q=Apfel", false},
		{"/?q=&sort_by=_text_match%3Adesc%2Ccreated_at%3Adesc%2Crecipe_id_sort%3Aasc", "/?sort_by=_text_match%3Adesc%2Ccreated_at%3Adesc%2Crecipe_id_sort%3Aasc", false},
		{"/?sort=rating", "/", false},
		{"/?q=&sort_by=created_at%3Adesc%2Crecipe_id_sort%3Aasc&page=2", "/?page=2&sort_by=created_at%3Adesc%2Crecipe_id_sort%3Aasc", false},
		{"/?q=&sort_by=", "", true},
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

func TestBrowseTagFilterReachesSearchAndSurvivesPageRestoration(t *testing.T) {
	const tagID = `tag/"?&+`
	filter := components.TagSearchFilter(tagID)
	var pages []int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			OperationName string
			Variables     map[string]json.RawMessage
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
		}
		data := map[string]any{"searchOnline": true, "ratingsOnline": false}
		switch request.OperationName {
		case "BrowseServices":
		case "TagInventory":
			data = map[string]any{"tags": []any{
				map[string]any{"id": tagID, "category": "COURSE", "name": "E2E Tag"},
			}}
		case "BrowseSearch":
			var options browseOptions
			if err := json.Unmarshal(request.Variables["options"], &options); err != nil {
				t.Error(err)
			}
			if options.Query != "*" || options.FilterBy == nil || *options.FilterBy != filter ||
				options.PerPage != browsePageSize {
				t.Errorf("tag filter was not forwarded verbatim: %+v", options)
			}
			pages = append(pages, options.Page)
			ids := []string{"first"}
			if options.Page == 2 {
				ids = []string{"first", "second"}
			}
			recipes := make([]any, 0, len(ids))
			for _, id := range ids {
				recipes = append(recipes, map[string]any{"id": id, "name": id, "tags": []any{}})
			}
			data = map[string]any{"searchRecipes": map[string]any{
				"recipes": recipes, "found": 25, "page": options.Page, "perPage": browsePageSize,
			}}
		default:
			t.Errorf("unexpected operation: %s", request.OperationName)
		}
		if err := json.NewEncoder(w).Encode(map[string]any{"data": data}); err != nil {
			t.Error(err)
		}
	}))
	defer upstream.Close()
	handler := newHandler(graphql.NewClient(upstream.URL, upstream.Client()), nil)

	for _, page := range []int{1, 2} {
		pages = nil
		values := url.Values{"filter_by": {filter}}
		if page > 1 {
			values.Set("page", strconv.Itoa(page))
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest("GET", "/?"+values.Encode(), nil))
		body := html.UnescapeString(response.Body.String())
		wantPages := []int{1}
		if page == 2 {
			wantPages = []int{1, 2}
		}
		if response.Code != http.StatusOK || !reflect.DeepEqual(pages, wantPages) ||
			!strings.Contains(body, `<h1 id="browse-heading">Suchergebnisse für Tag „E2E Tag“</h1>`) ||
			!strings.Contains(body, `name="q"`) || !strings.Contains(body, `value=""`) ||
			!strings.Contains(body, `name="filter_by" value="`+filter+`"`) {
			t.Fatalf("tag filter state was not rendered or restored: %d pages=%v %s", response.Code, pages, body)
		}
		wantCards := 1
		if page == 2 {
			wantCards = 2
		}
		if strings.Count(body, `data-recipe-id=`) != wantCards {
			t.Fatalf("page restoration did not deduplicate recipe cards: %s", body)
		}
		if page == 1 {
			if !strings.Contains(body, `hx-get="/?filter_by=`) || !strings.Contains(body, `&page=2"`) {
				t.Fatalf("pagination URL lost the active filter: %s", body)
			}
		}
	}
}

func TestBrowseFilterFailureNeverFallsBackToUnfilteredRecipes(t *testing.T) {
	for _, searchOnline := range []bool{false, true} {
		t.Run(strconv.FormatBool(searchOnline), func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var request struct{ OperationName string }
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
				}
				if request.OperationName != "BrowseServices" && request.OperationName != "BrowseSearch" {
					t.Errorf("filtered search unexpectedly called %s", request.OperationName)
				}
				if request.OperationName == "BrowseServices" {
					_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{
						"searchOnline": searchOnline, "ratingsOnline": false,
					}})
					return
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"errors": []any{
					map[string]any{"message": "invalid Typesense filter", "extensions": map[string]any{
						"code": "invalid-search-options", "status": http.StatusBadRequest,
					}},
				}})
			}))
			defer upstream.Close()
			handler := newHandler(graphql.NewClient(upstream.URL, upstream.Client()), nil)
			query := url.Values{"filter_by": {`unknown_field:="value"`}}.Encode()
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, httptest.NewRequest("GET", "/?"+query, nil))
			body := response.Body.String()
			wantStatus := http.StatusBadRequest
			if !searchOnline {
				wantStatus = http.StatusFailedDependency
			}
			if response.Code != wantStatus ||
				!strings.Contains(body, "Suchfilter konnten nicht angewendet werden.") ||
				strings.Contains(body, "data-recipe-id") ||
				strings.Contains(body, "Suche nicht verfügbar. Alle Rezepte werden angezeigt.") {
				t.Fatalf("filter failure was not explicit and isolated: %d %s", response.Code, body)
			}
		})
	}
}

func TestBrowseInvalidNativeSortReachesSearchAndIsReported(t *testing.T) {
	const sortBy = "unknown_sort_field:desc"
	for _, fragment := range []bool{false, true} {
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var request struct {
				OperationName string
				Variables     map[string]json.RawMessage
			}
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Error(err)
			}
			if request.OperationName == "BrowseServices" {
				_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{
					"searchOnline": true, "ratingsOnline": false,
				}})
				return
			}
			if request.OperationName != "BrowseSearch" {
				t.Errorf("unexpected operation: %s", request.OperationName)
			}
			var options map[string]any
			if err := json.Unmarshal(request.Variables["options"], &options); err != nil {
				t.Error(err)
			}
			if options["sort_by"] != sortBy {
				t.Errorf("native sort was rewritten: %#v", options["sort_by"])
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"errors": []any{
				map[string]any{"message": "invalid Typesense sort", "extensions": map[string]any{
					"code": "invalid-search-options", "status": http.StatusBadRequest,
				}},
			}})
		}))
		handler := newHandler(graphql.NewClient(upstream.URL, upstream.Client()), nil)
		request := httptest.NewRequest(http.MethodGet, "/?sort_by="+url.QueryEscape(sortBy), nil)
		if fragment {
			request.Header.Set("HX-Request", "true")
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		upstream.Close()

		wantStatus, wantMessage := http.StatusBadRequest, "Sortierung konnte nicht angewendet werden."
		if fragment {
			wantStatus = http.StatusOK
		}
		body := html.UnescapeString(response.Body.String())
		if response.Code != wantStatus || !strings.Contains(body, wantMessage) ||
			strings.Contains(body, `data-recipe-id=`) {
			t.Fatalf("invalid native sort was not reported explicitly: %d %s", response.Code, body)
		}
		if fragment && (!strings.Contains(body, `data-kind="error"`) ||
			!strings.Contains(body, `data-browse-status`)) {
			t.Fatalf("HTMX error did not replace successful results with an error state: %s", body)
		}
	}
}

func TestBrowseInvalidSearchOptionsUseGenericErrorWhenUnattributed(t *testing.T) {
	for _, fragment := range []bool{false, true} {
		for _, options := range []string{
			"filter_by=unknown_field%3A%3D%22value%22&sort_by=unknown_sort_field%3Adesc",
			"q=very-long-query",
		} {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var request struct{ OperationName string }
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
				}
				if request.OperationName == "BrowseServices" {
					_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{
						"searchOnline": true, "ratingsOnline": false,
					}})
					return
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"errors": []any{
					map[string]any{"message": "invalid search options", "extensions": map[string]any{
						"code": "invalid-search-options", "status": http.StatusBadRequest,
					}},
				}})
			}))
			handler := newHandler(graphql.NewClient(upstream.URL, upstream.Client()), nil)
			request := httptest.NewRequest(http.MethodGet, "/?"+options, nil)
			if fragment {
				request.Header.Set("HX-Request", "true")
			}
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			upstream.Close()

			body := html.UnescapeString(response.Body.String())
			wantStatus := http.StatusBadRequest
			if fragment {
				wantStatus = http.StatusOK
			}
			if response.Code != wantStatus ||
				!strings.Contains(body, "Ungültige Suchparameter.") ||
				strings.Contains(body, "Suchfilter konnten nicht angewendet werden.") ||
				strings.Contains(body, "Sortierung konnte nicht angewendet werden.") ||
				strings.Contains(body, `data-recipe-id=`) {
				t.Fatalf("unattributed invalid options did not produce a generic empty error state: %d %s", response.Code, body)
			}
			if fragment && !strings.Contains(body, "<title>Ungültige Suchparameter | RezeptDB</title>") {
				t.Fatalf("HTMX error title was not generic: %s", body)
			}
		}
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
					if options.Query != "Apfel" || options.SortBy != "rating_average:desc,rating_count:desc,recipe_id_sort:asc" || options.Page > tc.page || options.PerPage != 24 {
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
				query := url.Values{"q": {"Apfel"}, "sort_by": {"rating_average:desc,rating_count:desc,recipe_id_sort:asc"}, "page": {strconv.Itoa(tc.page)}}.Encode()
				if tc.page == 1 {
					query = url.Values{"q": {"Apfel"}, "sort_by": {"rating_average:desc,rating_count:desc,recipe_id_sort:asc"}}.Encode()
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
						!strings.Contains(body, `class="feedback error"`) ||
						!strings.Contains(body, `<button type="button" class="outline"`) ||
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
				if strings.Contains(body, `id="browse-pagination"`) != more ||
					strings.Contains(body, `aria-label="Weitere Rezepte werden geladen"`) != more {
					t.Fatal("pagination used card count instead of API metadata")
				}
				if more && !strings.Contains(body, `hx-get="/?page=`+strconv.Itoa(tc.page+1)+`&q=Apfel&sort_by=rating_average%3Adesc%2Crating_count%3Adesc%2Crecipe_id_sort%3Aasc"`) {
					t.Fatalf("missing automatic pagination request: %s", body)
				}
				if strings.Contains(body, "data-add-recipe") {
					t.Fatal("privileged add affordance must remain in the dynamic controls fragment")
				}
				if tc.kind == "search" && tc.hits == 0 && !strings.Contains(body, "Keine Rezepte gefunden.") {
					t.Fatal("empty successful search not distinguished")
				}
				if !fragment && !fullPageError && (!strings.Contains(body, `value="Apfel"`) || !strings.Contains(body, `value="rating_average:desc,rating_count:desc,recipe_id_sort:asc" selected`) ||
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
