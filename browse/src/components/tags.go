package components

import (
	"sort"
	"strings"

	gql "frontend/src/generated"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

type recipeTag struct {
	ID       string
	Category gql.TagCategory
	Name     string
}

func orderedTags(tags []recipeTag) []recipeTag {
	sort.Slice(tags, func(i, j int) bool {
		left, right := tags[i], tags[j]
		if left.Category != right.Category {
			return tagCategoryOrder(left.Category) < tagCategoryOrder(right.Category)
		}
		leftName := cases.Fold().String(norm.NFC.String(left.Name))
		rightName := cases.Fold().String(norm.NFC.String(right.Name))
		if leftName != rightName {
			return leftName < rightName
		}
		return left.ID < right.ID
	})
	return tags
}

func tagCategoryOrder(category gql.TagCategory) int {
	switch category {
	case gql.TagCategoryCuisine:
		return 0
	case gql.TagCategoryDietaryStyle:
		return 1
	case gql.TagCategoryCourse:
		return 2
	default:
		return 3
	}
}

func orderedStubTags(tags []gql.RecipeStubTagsTag) []recipeTag {
	ordered := make([]recipeTag, len(tags))
	for i, tag := range tags {
		ordered[i] = recipeTag{ID: tag.Id, Category: tag.Category, Name: tag.Name}
	}
	return orderedTags(ordered)
}

func orderedDetailTags(tags []gql.RecipeDetailTagsTag) []recipeTag {
	ordered := make([]recipeTag, len(tags))
	for i, tag := range tags {
		ordered[i] = recipeTag{ID: tag.Id, Category: tag.Category, Name: tag.Name}
	}
	return orderedTags(ordered)
}

func tagCategoryLabel(category gql.TagCategory) string {
	switch category {
	case gql.TagCategoryCuisine:
		return "Cuisine"
	case gql.TagCategoryDietaryStyle:
		return "Dietary style"
	case gql.TagCategoryCourse:
		return "Course"
	default:
		return "Tag"
	}
}

func tagClass(category gql.TagCategory) string {
	switch category {
	case gql.TagCategoryCuisine:
		return "recipe-tag recipe-tag--cuisine"
	case gql.TagCategoryDietaryStyle:
		return "recipe-tag recipe-tag--dietary-style"
	case gql.TagCategoryCourse:
		return "recipe-tag recipe-tag--course"
	default:
		return "recipe-tag"
	}
}

func recipeAccessibleLabel(recipe gql.RecipeStub) string {
	labels := []string{"Rezept " + recipe.Name}
	for _, tag := range orderedStubTags(recipe.Tags) {
		labels = append(labels, tagCategoryLabel(tag.Category)+": "+tag.Name)
	}
	return strings.Join(labels, ". ")
}
