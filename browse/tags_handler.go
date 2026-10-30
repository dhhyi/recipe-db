package main

import (
	"bytes"
	"errors"
	"log"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"unicode/utf8"

	"github.com/Khan/genqlient/graphql"
	"github.com/a-h/templ"
	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"

	"frontend/src/components"
	gql "frontend/src/generated"
)

var errInvalidTagRequest = errors.New("invalid tag request")
var errTagForbidden = errors.New("tag editing is not allowed")

func loadRecipeTags(r *http.Request, client graphql.Client, id string) ([]components.RecipeTag, bool, error) {
	response, err := gql.RecipeTags(r.Context(), client, id)
	if err != nil && !tagErrorsOnly(err) {
		return nil, false, err
	}
	if response == nil || response.Recipe == nil {
		if err == nil {
			return nil, false, errRecipeNotFound
		}
		return nil, false, err
	}
	if err != nil || response.Recipe.Tags == nil {
		return nil, response.MyCapabilities.CanManageRecipes, errTagsUnavailable
	}
	tags := make([]components.RecipeTag, len(response.Recipe.Tags))
	for index, tag := range response.Recipe.Tags {
		tags[index] = components.RecipeTag{ID: tag.Id, Category: tag.Category, Name: tag.Name}
	}
	return tags, response.MyCapabilities.CanManageRecipes, nil
}

func loadTagInventory(r *http.Request, client graphql.Client) ([]components.RecipeTag, error) {
	response, err := gql.TagInventory(r.Context(), client)
	if err != nil {
		return nil, err
	}
	if response == nil || response.Tags == nil {
		return nil, errTagsUnavailable
	}
	tags := make([]components.RecipeTag, len(response.Tags))
	for index, tag := range response.Tags {
		tags[index] = components.RecipeTag{ID: tag.Id, Category: tag.Category, Name: tag.Name}
	}
	return tags, nil
}

func tagQuery(r *http.Request) (string, error) {
	values, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil || len(values) > 1 || len(values["q"]) > 1 {
		return "", errInvalidTagRequest
	}
	for key := range values {
		if key != "q" {
			return "", errInvalidTagRequest
		}
	}
	query := strings.TrimSpace(values.Get("q"))
	if len(query) > 200 || !utf8.ValidString(query) {
		return "", errInvalidTagRequest
	}
	return query, nil
}

func tagSearchKey(value string) string {
	return cases.Fold().String(norm.NFC.String(value))
}

func unassignedTagOptions(tags, assigned []components.RecipeTag, query string) []components.RecipeTag {
	assignedIDs := make(map[string]bool, len(assigned))
	for _, tag := range assigned {
		assignedIDs[tag.ID] = true
	}
	key := tagSearchKey(query)
	options := make([]components.RecipeTag, 0, len(tags))
	for _, tag := range tags {
		if !assignedIDs[tag.ID] && strings.Contains(tagSearchKey(tag.Name), key) {
			options = append(options, tag)
		}
	}
	return options
}

func tagRequestStatus(err error, upstreamStatus int) int {
	if errors.Is(err, errRecipeNotFound) {
		return http.StatusNotFound
	}
	if errors.Is(err, errInvalidTagRequest) {
		return http.StatusBadRequest
	}
	if errors.Is(err, errTagForbidden) {
		return http.StatusForbidden
	}
	if err != nil {
		if status := ratingAuthorizationStatus(err, upstreamStatus); status != 0 {
			return status
		}
	}
	return http.StatusBadGateway
}

func writeTagComponent(w http.ResponseWriter, r *http.Request, status int, component templ.Component, replace, added, removed bool) {
	var body bytes.Buffer
	if err := component.Render(r.Context(), &body); err != nil {
		log.Printf("failed to render recipe tags: %v", err)
		http.Error(w, "failed to render recipe tags", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Del("ETag")
	if replace {
		w.Header().Set("X-Tag-Replace", "true")
	}
	if added {
		w.Header().Set("HX-Trigger-After-Swap", `{"recipe-tags-added":{"target":"#recipe-tags"}}`)
	}
	if removed {
		w.Header().Set("HX-Trigger-After-Swap", `{"recipe-tag-removed":{"target":"#recipe-tags"}}`)
	}
	w.WriteHeader(status)
	if r.Method != http.MethodHead {
		if _, err := w.Write(body.Bytes()); err != nil {
			log.Printf("failed to serve recipe tags: %v", err)
		}
	}
}

func tagsWidget(id string, tags []components.RecipeTag, owner, edit, pickerOpen bool, feedback string, failed bool) templ.Component {
	return components.RecipeTagsWidget(id, tags, owner, edit, pickerOpen, feedback, failed)
}

func writeTagFailure(w http.ResponseWriter, r *http.Request, id string, status int, message string, replace bool) {
	writeTagComponent(w, r, status, tagsWidget(id, nil, false, false, false, message, true), replace, false, false)
}

func parseTagEditMode(r *http.Request) (bool, error) {
	values, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil || len(values) > 1 || len(values["edit"]) > 1 {
		return false, errInvalidTagRequest
	}
	for key := range values {
		if key != "edit" {
			return false, errInvalidTagRequest
		}
	}
	if len(values["edit"]) == 0 || values.Get("edit") == "0" {
		return false, nil
	}
	if values.Get("edit") == "1" {
		return true, nil
	}
	return false, errInvalidTagRequest
}

func recipeTagsHandler(endpoint string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if id == "" {
			writeTagFailure(w, r, id, http.StatusBadRequest, "Rezept-ID fehlt.", true)
			return
		}
		edit, err := parseTagEditMode(r)
		if err != nil {
			writeTagFailure(w, r, id, http.StatusBadRequest, "Ungültige Tags-Anfrage.", true)
			return
		}
		client, upstreamStatus := requestScopedClient(endpoint, r, w)
		tags, owner, err := loadRecipeTags(r, client, id)
		if err != nil {
			status := tagRequestStatus(err, *upstreamStatus)
			message := "Tags konnten nicht geladen werden."
			if status == http.StatusNotFound {
				message = "Rezept nicht gefunden."
			} else if status == http.StatusUnauthorized || status == http.StatusForbidden {
				message = "Tags bearbeiten ist nicht erlaubt."
			}
			writeTagFailure(w, r, id, status, message, status != http.StatusBadGateway)
			return
		}
		if edit && !owner {
			writeTagComponent(w, r, http.StatusForbidden,
				tagsWidget(id, tags, false, false, false, "Tags bearbeiten ist nicht erlaubt.", true),
				true, false, false)
			return
		}
		writeTagComponent(w, r, http.StatusOK, tagsWidget(id, tags, owner, edit, edit, "", false), true, false, false)
	}
}

func recipeTagOptionsHandler(endpoint string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		query, err := tagQuery(r)
		if err != nil {
			component := components.TagOptionsError(r.URL.RequestURI(), "Ungültige Suchanfrage.")
			writeTagComponent(w, r, http.StatusBadRequest, component, false, false, false)
			return
		}
		client, upstreamStatus := requestScopedClient(endpoint, r, w)
		assigned, owner, err := loadRecipeTags(r, client, id)
		if err == nil && !owner {
			err = errTagForbidden
		}
		if err != nil {
			status := tagRequestStatus(err, *upstreamStatus)
			message := "Tag-Auswahl ist nicht verfügbar."
			if status == http.StatusUnauthorized || status == http.StatusForbidden {
				message = "Tags bearbeiten ist nicht erlaubt."
				w.Header().Set("HX-Retarget", "#recipe-tags")
				w.Header().Set("HX-Reswap", "outerHTML")
				writeTagComponent(w, r, status,
					tagsWidget(id, assigned, false, false, false, message, true), true, false, false)
				return
			}
			if status == http.StatusNotFound {
				message = "Rezept nicht gefunden."
			}
			component := components.TagOptionsError(r.URL.RequestURI(), message)
			writeTagComponent(w, r, status, component, false, false, false)
			return
		}
		inventory, err := loadTagInventory(r, client)
		if err != nil {
			log.Printf("failed to fetch tag inventory: %v", err)
			status := tagRequestStatus(err, *upstreamStatus)
			if status == http.StatusUnauthorized || status == http.StatusForbidden {
				w.Header().Set("HX-Retarget", "#recipe-tags")
				w.Header().Set("HX-Reswap", "outerHTML")
				writeTagComponent(w, r, status,
					tagsWidget(id, assigned, false, false, false, "Tags bearbeiten ist nicht erlaubt.", true),
					true, false, false)
				return
			}
			message := "Tag-Auswahl konnte nicht geladen werden."
			if status == http.StatusNotFound {
				message = "Rezept nicht gefunden."
			}
			component := components.TagOptionsError(r.URL.RequestURI(), message)
			writeTagComponent(w, r, status, component, false, false, false)
			return
		}
		options := unassignedTagOptions(inventory, assigned, query)
		writeTagComponent(w, r, http.StatusOK, components.TagOptions(id, options), false, false, false)
	}
}

func parseTagID(w http.ResponseWriter, r *http.Request) (string, error) {
	if r.URL.RawQuery != "" || !isFormURLEncoded(r) {
		return "", errInvalidTagRequest
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	if err := r.ParseForm(); err != nil {
		return "", errInvalidTagRequest
	}
	if len(r.PostForm) != 1 || len(r.PostForm["tagId"]) != 1 {
		return "", errInvalidTagRequest
	}
	id := r.PostForm.Get("tagId")
	if strings.TrimSpace(id) == "" || len(id) > 256 || !utf8.ValidString(id) {
		return "", errInvalidTagRequest
	}
	return id, nil
}

func parseEmptyTagForm(w http.ResponseWriter, r *http.Request) error {
	if r.URL.RawQuery != "" || !isFormURLEncoded(r) {
		return errInvalidTagRequest
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	if err := r.ParseForm(); err != nil || len(r.PostForm) != 0 {
		return errInvalidTagRequest
	}
	return nil
}

func isFormURLEncoded(r *http.Request) bool {
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	return err == nil && mediaType == "application/x-www-form-urlencoded"
}

func invalidateRecipeTags(cache *pageCache, id string) error {
	if cache == nil {
		return nil
	}
	return cache.invalidate(id)
}

func writeCurrentTagEdit(w http.ResponseWriter, r *http.Request, id string, status int, tags []components.RecipeTag, message string, added, removed bool) {
	component := components.RecipeTagsWidget(id, tags, true, true, false, message, message != "")
	writeTagComponent(w, r, status, component, true, added, removed)
}

func writeTagEditDenied(w http.ResponseWriter, r *http.Request, id string, status int, tags []components.RecipeTag, message string) {
	writeTagComponent(w, r, status,
		components.RecipeTagsWidget(id, tags, false, false, false, message, true), true, false, false)
}

func recipeTagMutationHandler(endpoint string, cache *pageCache, remove bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, tagID := r.PathValue("id"), r.PathValue("tagId")
		if id == "" || remove && tagID == "" {
			writeTagFailure(w, r, id, http.StatusBadRequest, "Ungültige Tags-Anfrage.", true)
			return
		}
		if !sameOriginRequest(r) {
			writeTagFailure(w, r, id, http.StatusForbidden, "Anfrage wurde aus Sicherheitsgründen abgelehnt.", false)
			return
		}
		client, upstreamStatus := requestScopedClient(endpoint, r, w)
		tags, owner, err := loadRecipeTags(r, client, id)
		if err != nil {
			status := tagRequestStatus(err, *upstreamStatus)
			message := "Tags konnten nicht geladen werden; Änderung wurde nicht ausgeführt."
			if status == http.StatusUnauthorized || status == http.StatusForbidden {
				message = "Tags bearbeiten ist nicht erlaubt."
			}
			writeTagFailure(w, r, id, status, message, status != http.StatusBadGateway)
			return
		}
		if !owner {
			writeTagEditDenied(w, r, id, http.StatusForbidden, tags, "Tags bearbeiten ist nicht erlaubt.")
			return
		}
		var formTagID string
		if remove {
			err = parseEmptyTagForm(w, r)
		} else {
			formTagID, err = parseTagID(w, r)
		}
		if err != nil {
			writeCurrentTagEdit(w, r, id, http.StatusBadRequest, tags, "Ungültige Tags-Anfrage.", false, false)
			return
		}
		if remove {
			if tagID == "" {
				writeCurrentTagEdit(w, r, id, http.StatusBadRequest, tags, "Ungültige Tags-Anfrage.", false, false)
				return
			}
			found := false
			for _, tag := range tags {
				found = found || tag.ID == tagID
			}
			if !found {
				writeCurrentTagEdit(w, r, id, http.StatusBadRequest, tags, "Dieser Tag ist dem Rezept nicht zugeordnet.", false, false)
				return
			}
		} else {
			inventory, inventoryErr := loadTagInventory(r, client)
			if inventoryErr != nil {
				log.Printf("failed to verify tag before assignment: %v", inventoryErr)
				status := tagRequestStatus(inventoryErr, *upstreamStatus)
				if status == http.StatusUnauthorized || status == http.StatusForbidden {
					writeTagEditDenied(w, r, id, status, tags, "Tags bearbeiten ist nicht erlaubt.")
				} else {
					writeCurrentTagEdit(w, r, id, status, tags, "Tag-Auswahl konnte nicht geladen werden. Bitte erneut laden.", false, false)
				}
				return
			}
			found := false
			assigned := false
			for _, tag := range inventory {
				found = found || tag.ID == formTagID
			}
			for _, tag := range tags {
				assigned = assigned || tag.ID == formTagID
			}
			if !found || assigned {
				writeCurrentTagEdit(w, r, id, http.StatusBadRequest, tags, "Dieser Tag ist nicht verfügbar.", false, false)
				return
			}
			tagID = formTagID
		}
		var changed bool
		if remove {
			response, mutationErr := gql.RemoveRecipeTag(r.Context(), client, id, tagID)
			err = mutationErr
			changed = response != nil && response.RemoveRecipeTag != nil && *response.RemoveRecipeTag
		} else {
			response, mutationErr := gql.AddRecipeTag(r.Context(), client, id, tagID)
			err = mutationErr
			changed = response != nil && response.AddRecipeTag != nil && *response.AddRecipeTag
		}
		if err == nil && !changed {
			err = errors.New("tag mutation was not confirmed")
		}
		if err != nil {
			log.Printf("failed to change recipe tag assignment: %v", err)
			if cacheErr := invalidateRecipeTags(cache, id); cacheErr != nil {
				log.Printf("failed to invalidate uncertain recipe tag assignment: %v", cacheErr)
			}
			status := tagRequestStatus(err, *upstreamStatus)
			message := "Änderung konnte nicht bestätigt werden. Die angezeigten Tags sind der letzte bestätigte Stand; bitte neu laden oder erneut versuchen."
			if status == http.StatusUnauthorized || status == http.StatusForbidden {
				message = "Tags bearbeiten ist nicht erlaubt."
				writeTagEditDenied(w, r, id, status, tags, message)
				return
			}
			writeCurrentTagEdit(w, r, id, status, tags, message, false, false)
			return
		}
		if err := invalidateRecipeTags(cache, id); err != nil {
			log.Printf("failed to invalidate tagged recipe: %v", err)
			writeCurrentTagEdit(w, r, id, http.StatusInternalServerError, tags,
				"Änderung wurde möglicherweise gespeichert, konnte aber nicht bestätigt werden. Bitte neu laden.",
				false, false)
			return
		}
		confirmedTags, confirmedOwner, err := loadRecipeTags(r, client, id)
		if err != nil {
			log.Printf("failed to confirm recipe tag assignment: %v", err)
			status := tagRequestStatus(err, *upstreamStatus)
			message := "Änderung wurde möglicherweise gespeichert, konnte aber nicht bestätigt werden. Bitte neu laden."
			if status == http.StatusUnauthorized || status == http.StatusForbidden {
				writeTagEditDenied(w, r, id, status, tags, message+" Tags bearbeiten ist nicht erlaubt.")
			} else {
				writeCurrentTagEdit(w, r, id, status, tags, message, false, false)
			}
			return
		}
		if !confirmedOwner {
			writeTagEditDenied(w, r, id, http.StatusForbidden, confirmedTags, "Tags bearbeiten ist nicht erlaubt.")
			return
		}
		added, removed := !remove, remove
		writeTagComponent(w, r, http.StatusOK,
			components.RecipeTagsWidget(id, confirmedTags, true, true, remove, "", false),
			true, added, removed)
	}
}
