package main

import (
	"testing"

	"github.com/vektah/gqlparser/v2/ast"
	"github.com/vektah/gqlparser/v2/gqlerror"
)

func TestTagErrorsOnlyAcceptsStructuredTagOutageErrors(t *testing.T) {
	err := gqlerror.List{{
		Message: "tags unavailable",
		Extensions: map[string]interface{}{
			"code":    "service-unavailable",
			"status":  503,
			"service": "tags",
		},
		Path: ast.Path{
			ast.PathName("searchRecipes"),
			ast.PathName("recipes"),
			ast.PathIndex(2),
			ast.PathName("tags"),
		},
	}}
	if !tagErrorsOnly(err) {
		t.Fatal("structured tag outages should not fail recipe loading")
	}
}

func TestTagErrorsOnlyRejectsCoreFieldErrors(t *testing.T) {
	err := gqlerror.List{{
		Message: "recipe unavailable",
		Path:    ast.Path{ast.PathName("recipe"), ast.PathName("name")},
	}}
	if tagErrorsOnly(err) {
		t.Fatal("core recipe errors must not be treated as tag-only degradation")
	}
}

func TestOptionalServiceErrorsAcceptsIndependentRecipeEnrichmentOutages(t *testing.T) {
	err := gqlerror.List{
		{
			Message: "ratings unavailable",
			Extensions: map[string]interface{}{
				"code": "service-unavailable", "status": 503, "service": "ratings",
			},
			Path: ast.Path{ast.PathName("searchRecipes"), ast.PathName("recipes"), ast.PathIndex(1), ast.PathName("rating")},
		},
		{
			Message: "images unavailable",
			Extensions: map[string]interface{}{
				"code": "service-unavailable", "status": 503, "service": "images",
			},
			Path: ast.Path{ast.PathName("searchRecipes"), ast.PathName("recipes"), ast.PathIndex(2), ast.PathName("image")},
		},
		{
			Message: "recipe unavailable",
			Extensions: map[string]interface{}{
				"code": "service-unavailable", "status": 503, "service": "recipes",
			},
			Path: ast.Path{ast.PathName("searchRecipes"), ast.PathName("recipes"), ast.PathIndex(3)},
		},
	}
	if !optionalServiceErrors(err) {
		t.Fatal("optional enrichment outages should preserve usable recipe data")
	}
}

func TestOptionalServiceErrorsRejectsNonOutageRecipeErrors(t *testing.T) {
	for _, path := range []ast.Path{
		{ast.PathName("recipe")},
		{ast.PathName("searchRecipes"), ast.PathName("recipes"), ast.PathIndex(0), ast.PathName("name")},
	} {
		err := gqlerror.List{{
			Message: "recipe unavailable",
			Extensions: map[string]interface{}{
				"code": "service-unavailable", "status": 503, "service": "recipes",
			},
			Path: path,
		}}
		if optionalServiceErrors(err) {
			t.Fatalf("non-item recipe error was accepted: %#v", path)
		}
	}
}

func TestOptionalServiceErrorsRejectsNonOutageAndAvailabilityErrors(t *testing.T) {
	for _, gqlErr := range []*gqlerror.Error{
		{
			Message: "forbidden",
			Extensions: map[string]interface{}{
				"code": "forbidden", "status": 403, "service": "tags",
			},
			Path: ast.Path{ast.PathName("recipe"), ast.PathName("tags")},
		},
		{
			Message: "discovery unavailable",
			Extensions: map[string]interface{}{
				"code": "service-unavailable", "status": 503, "service": "traefik",
			},
			Path: ast.Path{ast.PathName("isServiceOnline")},
		},
	} {
		if optionalServiceErrors(gqlerror.List{gqlErr}) {
			t.Fatalf("non-optional error was accepted: %#v", gqlErr)
		}
	}
}
