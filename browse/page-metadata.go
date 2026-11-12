package main

import (
	"net/url"
	"os"
	"strings"

	"frontend/page_metadata"
	"frontend/src/components"
	gql "frontend/src/generated"
)

const (
	defaultPublicOrigin = "http://localhost:8080"
	siteDescription     = "Entdecke und teile vielfältige Rezepte auf RezeptDB."
	fallbackImagePath   = "/design/og-image.svg"
)

func publicOrigin() string {
	origin := strings.TrimRight(os.Getenv("PUBLIC_ORIGIN"), "/")
	if origin == "" {
		return defaultPublicOrigin
	}
	return origin
}

func browsePageMetadata(origin string, state components.BrowseState) pagemetadata.PageMetadata {
	return pagemetadata.PageMetadata{
		DocumentTitle:  state.Title(),
		OpenGraphTitle: "RezeptDB",
		OpenGraphType:  "website",
		OpenGraphImage: absolutePublicURL(origin, fallbackImagePath),
		OpenGraphURL:   absolutePublicURL(origin, "/"),
		Description:    state.Heading(),
	}
}

func recipePageMetadata(origin string, recipe *gql.RecipeDetail) pagemetadata.PageMetadata {
	image := fallbackImagePath
	if recipe.Image != nil && recipe.Image.Url != "" {
		image = recipe.Image.Url
	}
	return pagemetadata.PageMetadata{
		DocumentTitle:  recipe.Name + " | RezeptDB",
		OpenGraphTitle: recipe.Name,
		OpenGraphType:  "article",
		OpenGraphImage: absolutePublicURL(origin, image),
		OpenGraphURL:   absolutePublicURL(origin, "/recipe/"+url.PathEscape(recipe.Id)),
		Description:    siteDescription,
	}
}

func absolutePublicURL(origin, path string) string {
	base, err := url.Parse(strings.TrimRight(origin, "/") + "/")
	if err != nil ||
		(!strings.EqualFold(base.Scheme, "http") && !strings.EqualFold(base.Scheme, "https")) ||
		base.Host == "" {
		base, _ = url.Parse(defaultPublicOrigin + "/")
	}
	reference, err := url.Parse(path)
	if err != nil || reference.Scheme != "" &&
		(!strings.EqualFold(reference.Scheme, "http") && !strings.EqualFold(reference.Scheme, "https") ||
			reference.Host == "") {
		reference, _ = url.Parse(fallbackImagePath)
	}
	return base.ResolveReference(reference).String()
}
