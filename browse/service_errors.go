package main

import (
	"errors"
	"strings"

	"github.com/vektah/gqlparser/v2/ast"
	"github.com/vektah/gqlparser/v2/gqlerror"
)

func tagErrorsOnly(err error) bool {
	return serviceUnavailableOnly(err, map[string]string{"tags": "tags"})
}

func optionalServiceErrors(err error) bool {
	return serviceUnavailableOnly(err, map[string]string{
		"ratings":      "rating,myRating",
		"images":       "image",
		"inspirations": "inspirations",
		"tags":         "tags",
		"link-extract": "extracted",
		"image-inline": "inlinedFavicon",
	})
}

func serviceUnavailableOnly(err error, allowed map[string]string) bool {
	if err == nil {
		return false
	}
	var list gqlerror.List
	if !errors.As(err, &list) || len(list) == 0 {
		return false
	}
	for _, gqlErr := range list {
		if gqlErr == nil || len(gqlErr.Path) == 0 ||
			gqlErr.Extensions["code"] != "service-unavailable" ||
			statusCode(gqlErr.Extensions["status"]) != 503 {
			return false
		}
		service, ok := gqlErr.Extensions["service"].(string)
		if !ok {
			return false
		}
		if service == "recipes" && isSearchRecipeItemPath(gqlErr.Path) {
			continue
		}
		fields, ok := allowed[service]
		if !ok || !isOptionalFieldPath(gqlErr.Path, fields) {
			return false
		}
	}
	return true
}

func isSearchRecipeItemPath(path ast.Path) bool {
	if len(path) != 3 {
		return false
	}
	root, rootOK := path[0].(ast.PathName)
	field, fieldOK := path[1].(ast.PathName)
	_, itemOK := path[2].(ast.PathIndex)
	return rootOK && string(root) == "searchRecipes" &&
		fieldOK && string(field) == "recipes" && itemOK
}

func serviceUnavailableField(err error, service, field string) bool {
	list, ok := err.(gqlerror.List)
	if !ok {
		return false
	}
	for _, gqlErr := range list {
		if gqlErr == nil || gqlErr.Extensions["code"] != "service-unavailable" ||
			statusCode(gqlErr.Extensions["status"]) != 503 || gqlErr.Extensions["service"] != service {
			continue
		}
		if isOptionalFieldPath(gqlErr.Path, field) {
			return true
		}
	}
	return false
}

func statusCode(value any) int {
	switch value := value.(type) {
	case int:
		return value
	case int32:
		return int(value)
	case int64:
		return int(value)
	case float64:
		if value == 503 {
			return 503
		}
		return 0
	default:
		return 0
	}
}

func isOptionalFieldPath(path ast.Path, fields string) bool {
	last, ok := path[len(path)-1].(ast.PathName)
	if !ok {
		return false
	}
	for _, field := range strings.Split(fields, ",") {
		if string(last) == field {
			return true
		}
	}
	return false
}
