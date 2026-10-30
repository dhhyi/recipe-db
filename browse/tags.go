package main

import (
	"errors"

	"frontend/src/components"
	gql "frontend/src/generated"

	"github.com/vektah/gqlparser/v2/ast"
	"github.com/vektah/gqlparser/v2/gqlerror"
)

func tagErrorsOnly(err error) (bool, []int) {
	if err == nil {
		return false, nil
	}
	var list gqlerror.List
	if !errors.As(err, &list) || len(list) == 0 {
		return false, nil
	}
	indexes := make([]int, 0, len(list))
	for _, gqlErr := range list {
		if gqlErr == nil || len(gqlErr.Path) == 0 {
			return false, nil
		}
		if !isRecipeTagsPath(gqlErr.Path) {
			return false, nil
		}
		indexes = append(indexes, recipeTagPathIndex(gqlErr.Path))
	}
	return true, indexes
}

func isRecipeTagsPath(path ast.Path) bool {
	if len(path) == 0 {
		return false
	}
	last, ok := path[len(path)-1].(ast.PathName)
	return ok && string(last) == "tags"
}

func recipeTagPathIndex(path ast.Path) int {
	for i := len(path) - 2; i >= 0; i-- {
		if index, ok := path[i].(ast.PathIndex); ok {
			return int(index)
		}
	}
	return -1
}

func markUnavailableTags(state *components.BrowseState, recipes []gql.RecipeStub, indexes []int) {
	if state.TagUnavailableIDs == nil {
		state.TagUnavailableIDs = make(map[string]bool)
	}
	for _, recipe := range recipes {
		if recipe.Tags == nil {
			state.TagUnavailableIDs[recipe.Id] = true
		}
	}
	for _, index := range indexes {
		if index >= 0 && index < len(recipes) {
			state.TagUnavailableIDs[recipes[index].Id] = true
		}
	}
}
