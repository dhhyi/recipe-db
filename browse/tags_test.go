package main

import (
	"testing"

	"github.com/vektah/gqlparser/v2/ast"
	"github.com/vektah/gqlparser/v2/gqlerror"
)

func TestTagErrorsOnlyAcceptsTagFieldErrors(t *testing.T) {
	err := gqlerror.List{{
		Message: "tags unavailable",
		Path: ast.Path{
			ast.PathName("searchRecipes"),
			ast.PathName("recipes"),
			ast.PathIndex(2),
			ast.PathName("tags"),
		},
	}}
	if !tagErrorsOnly(err) {
		t.Fatal("tag-only errors should not fail recipe loading")
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
