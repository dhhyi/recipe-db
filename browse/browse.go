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
const browseRestorePageLimit = 20

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
	query, sort, filterBy string
	filterByPresent       bool
	page                  int
}

type browseOptions struct {
	Query    string  `json:"q"`
	SortBy   string  `json:"sort_by"`
	FilterBy *string `json:"filter_by,omitempty"`
	Page     int     `json:"page"`
	PerPage  int     `json:"per_page"`
}

func parseBrowseRequest(values url.Values) (browseRequest, error) {
	_, filterByPresent := values["filter_by"]
	request := browseRequest{
		query: strings.TrimSpace(values.Get("q")), sort: values.Get("sort"),
		filterBy: values.Get("filter_by"), filterByPresent: filterByPresent, page: 1,
	}
	for _, key := range []string{"q", "sort", "page", "filter_by"} {
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
	var filterBy *string
	if request.filterByPresent {
		filterBy = &request.filterBy
	}
	options, _ := json.Marshal(browseOptions{
		Query: query, SortBy: browseSorts[sort], FilterBy: filterBy,
		Page: request.page, PerPage: browsePageSize,
	})
	return options
}

func (request browseRequest) pageURL(page int) string {
	values := url.Values{}
	if request.query != "" {
		values.Set("q", request.query)
	}
	if request.filterByPresent {
		values.Set("filter_by", request.filterBy)
	}
	if request.sort != "" {
		values.Set("sort", request.sort)
	}
	if page > 1 {
		values.Set("page", strconv.Itoa(page))
	}
	if len(values) == 0 {
		return "/"
	}
	return "/?" + values.Encode()
}

func browseHandler(client graphql.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		fragment := r.Header.Get("HX-Request") == "true" &&
			r.Header.Get("HX-Boosted") != "true" &&
			r.Header.Get("HX-History-Restore-Request") != "true"
		appendPage := fragment && r.Header.Get("HX-Target") == "browse-pagination"
		request, err := parseBrowseRequest(r.URL.Query())
		if err == nil && !fragment && r.Header.Get("HX-History-Restore-Request") != "true" &&
			r.URL.RequestURI() != request.pageURL(request.page) {
			http.Redirect(w, r, request.pageURL(request.page), http.StatusFound)
			return
		}
		state := components.BrowseState{
			Query: request.query, Sort: request.sort, FilterBy: request.filterBy,
			FilterByPresent: request.filterByPresent, Page: request.page,
			PerPage: browsePageSize, Kind: "error",
		}
		status := http.StatusOK
		filterExecutionFailed := false
		if err != nil {
			log.Printf("invalid browse request: %v", err)
			state.Message = "Ungültige Suchparameter."
			status = http.StatusBadRequest
		} else {
			services, serviceErr := gql.BrowseServices(r.Context(), client)
			if serviceErr != nil {
				log.Printf("failed to fetch browse service status: %v", serviceErr)
				status = http.StatusBadGateway
				if request.filterBy != "" {
					status = http.StatusFailedDependency
					filterExecutionFailed = true
				}
			} else {
				state.RatingsOnline = services.RatingsOnline
				if !services.SearchOnline {
					if request.filterBy != "" {
						status = http.StatusFailedDependency
						filterExecutionFailed = true
					} else {
						overview, overviewErr := gql.Overview(r.Context(), client)
						optionalOnly := optionalServiceErrors(overviewErr)
						if overviewErr != nil && !optionalOnly || overview == nil {
							log.Printf("failed to fetch offline browse overview: %v", overviewErr)
							status = http.StatusBadGateway
						} else {
							state.Kind, state.Recipes = "fallback", overview.Recipes
							state.Found = len(overview.Recipes)
							state.Page = 1
							state.Message = "Suche nicht verfügbar. Alle Rezepte werden angezeigt."
						}
					}
				} else {
					if tagID, singleTag := components.TagSearchFilterID(request.filterBy); singleTag && request.query == "" {
						inventory, inventoryErr := gql.TagInventory(r.Context(), client)
						if inventoryErr != nil {
							log.Printf("failed to load tag label for filtered search: %v", inventoryErr)
							status = http.StatusFailedDependency
							filterExecutionFailed = true
						} else if inventory != nil {
							for _, tag := range inventory.Tags {
								if tag.Id == tagID {
									state.TagName = tag.Name
									break
								}
							}
						}
					}
					// Load-more fetches only its next batch. Native navigation and history
					// cache misses reconstruct the loaded depth without a client controller.
					seen := make(map[string]bool)
					firstPage := 1
					if appendPage {
						firstPage = request.page
						for _, id := range r.URL.Query()["seen"] {
							if !seen[id] {
								seen[id] = true
								state.SeenIDs = append(state.SeenIDs, id)
							}
						}
					} else if request.page > browseRestorePageLimit {
						// Very deep native/history navigation remains usable without an
						// unbounded fan-out: render its current page and disclose the limit.
						firstPage = request.page
						state.Message = "Es wird nur die aktuelle Ergebnisseite angezeigt."
					}
					for page := firstPage; status < http.StatusBadRequest && page <= request.page; page++ {
						pageRequest := request
						pageRequest.page = page
						response, searchErr := gql.BrowseSearch(r.Context(), client, pageRequest.options())
						optionalOnly := optionalServiceErrors(searchErr)
						if searchErr != nil && !optionalOnly || response == nil || response.SearchRecipes == nil {
							log.Printf("failed to search recipes: %v", searchErr)
							status = http.StatusBadGateway
							if request.filterBy != "" {
								status = http.StatusFailedDependency
								filterExecutionFailed = true
								if invalidSearchOptions(searchErr) {
									status = http.StatusBadRequest
								}
							}
							break
						}
						if searchErr != nil {
							log.Printf("search results contain unavailable recipe enrichment: %v", searchErr)
						}
						result := response.SearchRecipes
						if result.Page != page || result.PerPage != browsePageSize || result.Found < 0 {
							log.Printf("invalid browse search metadata: page=%d perPage=%d found=%d", result.Page, result.PerPage, result.Found)
							status = http.StatusBadGateway
							break
						} else {
							state.Kind, state.Found, state.Page = "search", result.Found, page
							for _, recipe := range result.Recipes {
								if recipe == nil {
									continue
								}
								if !seen[recipe.Id] {
									state.Recipes = append(state.Recipes, *recipe)
									seen[recipe.Id] = true
									state.SeenIDs = append(state.SeenIDs, recipe.Id)
								}
							}
							// Use hit metadata, not the number of successfully hydrated cards.
							if int64(result.Page)*int64(result.PerPage) < int64(result.Found) {
								state.NextURL = request.pageURL(page + 1)
							} else {
								state.NextURL = ""
								break
							}
						}
					}
				}
			}
		}
		if filterExecutionFailed {
			state.Message = "Suchfilter konnten nicht angewendet werden."
			state.Kind, state.Recipes, state.NextURL = "error", nil, ""
		} else if status >= 500 {
			if request.filterBy != "" {
				state.Message = "Suchfilter konnten nicht angewendet werden."
			} else {
				state.Message = "Rezepte konnten nicht geladen werden."
			}
			state.Kind, state.Recipes, state.NextURL = "error", nil, ""
		}
		if !fragment && status >= 400 {
			title, message := "Rezepte konnten nicht geladen werden | RezeptDB", "Rezepte konnten nicht geladen werden."
			if filterExecutionFailed {
				title, message = "Suchfilter konnten nicht angewendet werden | RezeptDB", "Suchfilter konnten nicht angewendet werden."
			} else if status == http.StatusBadRequest {
				title, message = "Ungültige Suchparameter | RezeptDB", "Ungültige Suchparameter."
			}
			writeErrorPage(w, r, status, title, message)
			return
		}
		if appendPage && state.Kind == "search" && state.NextURL == "" {
			state.Message = state.RecipeCount() + " gefunden. Alle Rezepte geladen."
		}
		var component templ.Component
		if appendPage && (status >= 500 || filterExecutionFailed) {
			// A failed load-more only replaces its trigger. Existing cards and the
			// successful title/URL survive, and retries never auto-trigger.
			component = components.BrowsePageError(state, request.pageURL(request.page))
			w.Header().Set("HX-Retarget", "#browse-pagination")
			w.Header().Set("HX-Reswap", "outerHTML")
			status = http.StatusOK
		} else if fragment {
			if state.Kind == "fallback" {
				w.Header().Set("HX-Retarget", "#browse-content")
				component = components.BrowseFallbackFragment(state)
			} else if appendPage {
				component = components.BrowsePage(state)
			} else {
				component = components.BrowseFragment(state)
			}
			w.Header().Set("HX-Replace-Url", request.pageURL(state.Page))
			// HTMX swaps successful HTML by default; application errors are rendered
			// as an explicit error state rather than leaving old-query cards visible.
			status = http.StatusOK
		} else {
			ctx := templ.WithChildren(r.Context(), components.Browse(state))
			r = r.WithContext(ctx)
			component = components.Layout(state.Title(), overviewOpenGraphMetadata(publicOrigin()))
			if r.Header.Get("HX-History-Restore-Request") == "true" {
				status = http.StatusOK
			}
		}
		var body bytes.Buffer
		if err := component.Render(r.Context(), &body); err != nil {
			log.Printf("failed to render browse: %v", err)
			writeErrorPage(w, r, http.StatusInternalServerError, "Rezepte konnten nicht geladen werden | RezeptDB", "Rezepte konnten nicht geladen werden.")
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(status)
		if _, err := w.Write(body.Bytes()); err != nil {
			log.Printf("failed to serve browse: %v", err)
		}
	}
}
