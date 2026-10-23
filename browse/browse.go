package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/Khan/genqlient/graphql"
	"github.com/a-h/templ"

	"frontend/src/components"
	gql "frontend/src/generated"
)

const browsePageSize = 24

var browseSorts = map[string]string{
	"relevance":    "_text_match:desc,created_at:desc,recipe_id_sort:asc",
	"rating":       "rating_average:desc,rating_count:desc,recipe_id_sort:asc",
	"rating-count": "rating_count:desc,rating_average:desc,recipe_id_sort:asc",
	"name-asc":     "name_sort:asc,recipe_id_sort:asc",
	"name-desc":    "name_sort:desc,recipe_id_sort:asc",
	"newest":       "created_at:desc,recipe_id_sort:asc",
	"updated":      "updated_at:desc,recipe_id_sort:asc",
}

type browseRequest struct {
	query, sort string
	page        int
}

type browseOptions struct {
	Query   string `json:"q"`
	SortBy  string `json:"sort_by"`
	Page    int    `json:"page"`
	PerPage int    `json:"per_page"`
}

func parseBrowseRequest(values url.Values) (browseRequest, error) {
	request := browseRequest{query: strings.TrimSpace(values.Get("q")), sort: values.Get("sort"), page: 1}
	for _, key := range []string{"q", "sort", "page"} {
		if len(values[key]) > 1 {
			return request, fmt.Errorf("duplicate %s parameter", key)
		}
	}
	if request.sort != "" {
		if _, ok := browseSorts[request.sort]; !ok {
			return request, fmt.Errorf("invalid sort: %q", request.sort)
		}
	}
	if raw, present := values["page"]; present {
		page, err := strconv.ParseInt(raw[0], 10, 32)
		if err != nil || page < 1 {
			return request, fmt.Errorf("invalid page: %q", raw[0])
		}
		request.page = int(page)
	}
	return request, nil
}

func (request browseRequest) options() json.RawMessage {
	query, sort := request.query, request.sort
	if sort == "" {
		sort = "relevance"
		if query == "" {
			sort = "newest"
		}
	}
	if query == "" {
		query = "*"
		if sort == "relevance" {
			sort = "newest"
		}
	}
	// This fixed structure contains no browser-supplied Typesense options.
	options, _ := json.Marshal(browseOptions{query, browseSorts[sort], request.page, browsePageSize})
	return options
}

func (request browseRequest) pageURL(page int) string {
	values := url.Values{}
	if request.query != "" {
		values.Set("q", request.query)
	}
	if request.sort != "" {
		values.Set("sort", request.sort)
	}
	values.Set("page", strconv.Itoa(page))
	return "/?" + values.Encode()
}

func browseHandler(client graphql.Client, fragment bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		request, err := parseBrowseRequest(r.URL.Query())
		if err == nil && !fragment && r.Header.Get("HX-History-Restore-Request") != "true" {
			values := r.URL.Query()
			changed := false
			if values.Has("q") && (values.Get("q") != request.query || request.query == "") {
				changed = true
				if request.query == "" {
					values.Del("q")
				} else {
					values.Set("q", request.query)
				}
			}
			if values.Has("sort") && request.sort == "" {
				values.Del("sort")
				changed = true
			}
			if changed {
				target := "/"
				if query := values.Encode(); query != "" {
					target += "?" + query
				}
				http.Redirect(w, r, target, http.StatusFound)
				return
			}
		}
		state := components.BrowseState{
			Query: request.query, Sort: request.sort, Page: request.page,
			PerPage: browsePageSize, Kind: "error",
		}
		status := http.StatusOK
		if err != nil {
			log.Printf("invalid browse request: %v", err)
			state.Message = "Ungültige Suchparameter."
			status = http.StatusBadRequest
		} else {
			services, serviceErr := gql.BrowseServices(r.Context(), client)
			if serviceErr != nil {
				log.Printf("failed to fetch browse service status: %v", serviceErr)
				status = http.StatusBadGateway
			} else {
				state.EditorOnline, state.RatingsOnline = services.RecipeEditOnline, services.RatingsOnline
				if !services.SearchOnline {
					overview, overviewErr := gql.Overview(r.Context(), client)
					if overviewErr != nil {
						log.Printf("failed to fetch offline browse overview: %v", overviewErr)
						status = http.StatusBadGateway
					} else {
						state.Kind, state.Recipes = "fallback", overview.Recipes
						state.Found = len(overview.Recipes)
						state.Page = 1
						state.Message = "Suche nicht verfügbar. Alle Rezepte werden angezeigt."
					}
				} else {
					response, searchErr := gql.BrowseSearch(r.Context(), client, request.options())
					if searchErr != nil {
						log.Printf("failed to search recipes: %v", searchErr)
						status = http.StatusBadGateway
					} else {
						result := response.SearchRecipes
						if result.Page != request.page || result.PerPage != browsePageSize || result.Found < 0 {
							log.Printf("invalid browse search metadata: page=%d perPage=%d found=%d", result.Page, result.PerPage, result.Found)
							status = http.StatusBadGateway
						} else {
							state.Kind, state.Recipes, state.Found = "search", result.Recipes, result.Found
							// Use hit metadata, not the number of successfully hydrated cards.
							if int64(result.Page)*int64(result.PerPage) < int64(result.Found) {
								state.NextURL = request.pageURL(request.page + 1)
							}
						}
					}
				}
			}
		}
		if status >= 500 {
			state.Message = "Rezepte konnten nicht geladen werden."
		}
		var component templ.Component = components.BrowseResults(state, true)
		if !fragment {
			ctx := templ.WithChildren(r.Context(), components.Browse(state))
			r = r.WithContext(ctx)
			component = components.Layout("Alle Rezepte | RezeptDB")
		}
		var body bytes.Buffer
		if err := component.Render(r.Context(), &body); err != nil {
			log.Printf("failed to render browse: %v", err)
			http.Error(w, "Rezepte konnten nicht geladen werden.", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(status)
		if _, err := w.Write(body.Bytes()); err != nil {
			log.Printf("failed to serve browse: %v", err)
		}
	}
}
