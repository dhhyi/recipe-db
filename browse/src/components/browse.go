package components

import gql "frontend/src/generated"

type BrowseState struct {
	Query, Sort, Kind, Message  string
	Page, PerPage, Found        int
	EditorOnline, RatingsOnline bool
	Recipes                     []gql.RecipeStub
	NextURL                     string
}

type browseSortOption struct {
	Token, Label string
}

var browseSortOptions = []browseSortOption{
	{"relevance", "Relevanz"},
	{"rating", "Beste Bewertung"},
	{"rating-count", "Meiste Bewertungen"},
	{"name-asc", "Name A-Z"},
	{"name-desc", "Name Z-A"},
	{"newest", "Neueste zuerst"},
	{"updated", "Zuletzt bearbeitet"},
}

func automaticSortLabel(query string) string {
	if query == "" {
		return "Automatisch: Neueste zuerst"
	}
	return "Automatisch: Relevanz"
}
