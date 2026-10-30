package main

import (
	"errors"

	"github.com/vektah/gqlparser/v2/ast"
	"github.com/vektah/gqlparser/v2/gqlerror"
)

func tagErrorsOnly(err error) bool {
	if err == nil {
		return false
	}
	var list gqlerror.List
	if !errors.As(err, &list) || len(list) == 0 {
		return false
	}
	for _, gqlErr := range list {
		if gqlErr == nil || len(gqlErr.Path) == 0 {
			return false
		}
		if !isRecipeTagsPath(gqlErr.Path) {
			return false
		}
	}
	return true
}

func isRecipeTagsPath(path ast.Path) bool {
	if len(path) == 0 {
		return false
	}
	last, ok := path[len(path)-1].(ast.PathName)
	return ok && string(last) == "tags"
}
