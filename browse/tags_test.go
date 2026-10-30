package main

import (
	"reflect"
	"testing"

	"github.com/vektah/gqlparser/v2/ast"
	"github.com/vektah/gqlparser/v2/gqlerror"
)

func TestTagErrorsOnlyExtractsAffectedRecipeIndex(t *testing.T) {
	err := gqlerror.List{{
		Message: "tags unavailable",
		Path: ast.Path{
			ast.PathName("searchRecipes"),
			ast.PathName("recipes"),
			ast.PathIndex(2),
			ast.PathName("tags"),
		},
	}}
	onlyTags, indexes := tagErrorsOnly(err)
	if !onlyTags || !reflect.DeepEqual(indexes, []int{2}) {
		t.Fatalf("unexpected tag error result: onlyTags=%t indexes=%v", onlyTags, indexes)
	}
}

func TestTagErrorsOnlyRejectsCoreFieldErrors(t *testing.T) {
	err := gqlerror.List{{
		Message: "recipe unavailable",
		Path:    ast.Path{ast.PathName("recipe"), ast.PathName("name")},
	}}
	if onlyTags, _ := tagErrorsOnly(err); onlyTags {
		t.Fatal("core recipe errors must not be treated as tag-only degradation")
	}
}
