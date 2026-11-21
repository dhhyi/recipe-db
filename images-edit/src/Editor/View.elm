module Editor.View exposing (view)

import Crop exposing (Crop)
import Editor.Types exposing (GalleryFeedbackKind(..), Model, MoveDirection(..), Msg(..), Phase(..), Session, canAdd, canDelete, canMove, imageLimit)
import File exposing (File)
import Html exposing (Html, a, button, div, h1, img, input, label, li, p, span, text)
import Html.Attributes exposing (accept, alt, attribute, class, disabled, href, id, src, style, type_)
import Html.Events exposing (on, onClick)
import Html.Keyed
import Json.Decode as D
import RecipeDB
import RemoteData
import Set exposing (Set)


view : Model -> Html Msg
view model =
    case model.capabilities of
        RemoteData.Success capabilities ->
            if capabilities.canManageImages then
                if model.phase == Viewing then
                    galleryView model

                else
                    editorView model

            else if capabilities.role == "anonymous" then
                accessPage model "Anmeldung erforderlich" "Zum Verwalten von Bildern ist eine Anmeldung erforderlich."

            else
                accessPage model "Keine Berechtigung" "Dein Konto darf Rezeptbilder nicht verwalten."

        RemoteData.Failure _ ->
            accessPage model "Zugriff nicht verfügbar" "Die Anmeldung konnte nicht geprüft werden."

        _ ->
            Html.main_ [ class "image-editor" ]
                [ div [ attribute "aria-busy" "true", attribute "aria-label" "Zugriff wird geprüft" ] []
                , a [ href ("/recipe/" ++ model.recipeId) ] [ text "Zurück zum Rezept" ]
                ]


accessPage : Model -> String -> String -> Html Msg
accessPage model title message =
    Html.main_ [ class "image-editor" ]
        [ h1 [ id "gallery-heading", attribute "tabindex" "-1" ] [ text title ]
        , p [ attribute "role" "alert", class "feedback error" ] [ text message ]
        , a [ href ("/recipe/" ++ model.recipeId) ] [ text "Zurück zum Rezept" ]
        ]


editorView : Model -> Html Msg
editorView model =
    let
        busy : Bool
        busy =
            model.phase == Saving
    in
    editorPage
        [ h1 [] [ text (model.recipeName |> Maybe.map (\name -> "Bild für " ++ name ++ " bearbeiten") |> Maybe.withDefault "Bild bearbeiten") ]
        , Maybe.withDefault (text "") (Maybe.map errorMessage model.error)
        , if model.phase == Editing then
            p [ attribute "role" "status", class "feedback warning" ]
                [ text "Ungespeicherter Zuschnitt. Verschieben Sie die Auswahl oder ziehen Sie an einem der acht Griffe." ]

          else
            text ""
        , case model.session of
            Just session ->
                sourceView model session

            Nothing ->
                loadingPlaceholder "Bild wird geladen"
        , div [ class "flex flex-wrap gap-2" ]
            [ button
                ([ type_ "button"
                 , disabled (not ((model.phase == Editing || model.phase == SaveFailed) && (model.session |> Maybe.map .previewReady |> Maybe.withDefault False)))
                 , onClick Save
                 ]
                    ++ (if busy then
                            [ attribute "aria-busy" "true" ]

                        else
                            []
                       )
                )
                [ text
                    (if model.phase == SaveFailed then
                        "Erneut speichern"

                     else
                        "Speichern"
                    )
                ]
            , button [ type_ "button", class "outline", disabled (busy || model.phase == Loading), onClick Close ]
                [ text "Abbrechen" ]
            ]
        , p []
            [ a
                [ href ("/recipe/" ++ model.recipeId)
                , attribute "aria-disabled" (boolString busy)
                , attribute "tabindex"
                    (if busy then
                        "-1"

                     else
                        "0"
                    )
                ]
                [ text "Zurück zum Rezept" ]
            ]
        ]


errorMessage : String -> Html Msg
errorMessage error =
    case error of
        "authentication-required" ->
            div [ attribute "role" "alert", class "feedback error" ]
                [ p [] [ text "Anmeldung erforderlich oder abgelaufen." ] ]

        "forbidden" ->
            div [ attribute "role" "alert", class "feedback error" ]
                [ p [] [ text "Keine Berechtigung zum Verwalten dieses Bildes." ] ]

        _ ->
            p [ attribute "role" "alert", class "feedback error" ] [ text error ]


boolString : Bool -> String
boolString value =
    if value then
        "true"

    else
        "false"


loadingPlaceholder : String -> Html Msg
loadingPlaceholder loadingLabel =
    div
        [ class "editor-image-area"
        , attribute "aria-busy" "true"
        , attribute "aria-label" loadingLabel
        ]
        []


editorPage : List (Html Msg) -> Html Msg
editorPage content =
    Html.main_ [ class "image-editor" ]
        content


editorStatus : Model -> Html Msg
editorStatus model =
    let
        message : String
        message =
            if model.galleryMutation /= Nothing && model.galleryError /= Nothing then
                "Der aktuelle Stand konnte nicht bestätigt werden. Die angezeigten Bilder stammen aus dem letzten erfolgreichen Laden."

            else if model.galleryMutation /= Nothing && model.galleryRefreshing then
                "Galerie wird aktualisiert. Die angezeigten Bilder zeigen den zuletzt geladenen Stand."

            else if model.galleryMutation /= Nothing then
                case model.galleryMutation |> Maybe.andThen .movement of
                    Just _ ->
                        "Bildreihenfolge wird gespeichert."

                    Nothing ->
                        "Bild wird gelöscht."

            else if model.phase == Viewing && model.savedFeedback then
                "Bild gespeichert."

            else if model.galleryRefreshing then
                "Rezeptbilder werden geladen."

            else
                ""
    in
    p
        ([ id "editor-status"
         , attribute "role" "status"
         , attribute "tabindex" "-1"
         , class
            (if model.phase == Viewing && model.savedFeedback && model.galleryMutation == Nothing then
                "feedback success save-feedback"

             else
                "editor-announcement"
            )
         ]
            ++ (if model.galleryRefreshing || (model.galleryMutation /= Nothing && model.galleryError == Nothing) then
                    [ attribute "aria-busy" "true" ]

                else
                    []
               )
        )
        [ text message ]


galleryFeedback : Model -> Html Msg
galleryFeedback model =
    case model.galleryFeedback of
        Just feedback ->
            case feedback.kind of
                DeletionSucceeded ->
                    p [ attribute "role" "status", class "feedback success" ] [ text feedback.message ]

                ImageAlreadyAbsent ->
                    p [ attribute "role" "status", class "feedback warning" ] [ text feedback.message ]

                DeletionUnconfirmed ->
                    p [ attribute "role" "alert", class "feedback error" ] [ text feedback.message ]

                ReorderingSucceeded ->
                    p [ attribute "role" "status", class "feedback success" ] [ text feedback.message ]

                ReorderingRejected ->
                    p [ attribute "role" "alert", class "feedback error" ] [ text feedback.message ]

                ReorderingUnconfirmed ->
                    p [ attribute "role" "alert", class "feedback error" ] [ text feedback.message ]

        Nothing ->
            text ""


galleryLoadError : Model -> Html Msg
galleryLoadError model =
    case model.galleryError of
        Just _ ->
            let
                message : String
                message =
                    case model.galleryMutation of
                        Just _ ->
                            "Rezeptbilder konnten nicht aktualisiert werden. Die angezeigten Bilder stammen aus dem letzten erfolgreichen Laden."

                        Nothing ->
                            "Rezeptbilder konnten nicht geladen werden."
            in
            p [ attribute "role" "alert", class "feedback error" ] [ text message ]

        Nothing ->
            text ""


galleryView : Model -> Html Msg
galleryView model =
    let
        fileDecoder : D.Decoder File
        fileDecoder =
            D.at [ "target", "files", "0" ] File.decoder

        images : Maybe (List RecipeDB.GalleryImage)
        images =
            case model.recipe of
                RemoteData.Success (Just recipe) ->
                    recipe.images

                _ ->
                    Nothing
    in
    editorPage
        [ div [ class "flex flex-wrap items-center justify-between gap-2" ]
            [ h1
                ([ id "gallery-heading", attribute "tabindex" "-1" ]
                    ++ (if model.savedFeedback then
                            [ attribute "aria-describedby" "editor-status" ]

                        else
                            []
                       )
                )
                [ text (model.recipeName |> Maybe.map (\name -> "Bilder für " ++ name ++ " verwalten") |> Maybe.withDefault "Rezeptbilder verwalten") ]
            , label [ class "gallery-add" ]
                [ text "Bild hinzufügen"
                , input
                    [ id "upload-image"
                    , type_ "file"
                    , accept "image/jpeg,image/png,.jpg,.jpeg,.png"
                    , attribute "aria-describedby" "gallery-file-help"
                    , disabled (not (canAdd model))
                    , on "change" (D.map GotFile fileDecoder)
                    ]
                    []
                ]
            ]
        , editorStatus model
        , galleryFeedback model
        , p [ id "gallery-file-help" ] [ text "JPEG oder PNG, maximal 10 MiB." ]
        , Maybe.withDefault (text "")
            (if model.galleryRefreshing || model.galleryError /= Nothing then
                Nothing

             else
                Maybe.map (\warning -> p [ class "feedback warning", attribute "role" "status" ] [ text warning ]) (Editor.Types.capacityWarning images)
            )
        , Maybe.withDefault (text "") (Maybe.map errorMessage model.error)
        , galleryLoadError model
        , if model.galleryError /= Nothing then
            button [ type_ "button", class "outline", onClick RetryGallery ] [ text "Erneut laden" ]

          else
            text ""
        , galleryContent model images model.failedThumbnails
        , p [] [ a [ href ("/recipe/" ++ model.recipeId) ] [ text "Zurück zum Rezept" ] ]
        ]


galleryContent : Model -> Maybe (List RecipeDB.GalleryImage) -> Set String -> Html Msg
galleryContent model images failed =
    case ( model.recipe, images ) of
        ( RemoteData.Success (Just _), Just entries ) ->
            div
                (if model.galleryRefreshing || (model.galleryMutation /= Nothing && model.galleryError == Nothing) then
                    [ attribute "aria-busy" "true" ]

                 else
                    []
                )
                [ p [] [ text (String.fromInt (List.length entries) ++ " / " ++ String.fromInt imageLimit) ]
                , if List.isEmpty entries then
                    p [] [ text "Kein Bild vorhanden." ]

                  else
                    Html.Keyed.node "ol"
                        [ class "gallery-list", attribute "aria-label" "Rezeptbilder" ]
                        (List.indexedMap (galleryRow model failed) entries)
                ]

        ( RemoteData.Success Nothing, _ ) ->
            errorMessage "Rezept nicht gefunden."

        ( RemoteData.Loading, _ ) ->
            div [ attribute "aria-busy" "true", attribute "aria-label" "Rezeptbilder werden geladen" ] []

        _ ->
            text ""


galleryRow : Model -> Set String -> Int -> RecipeDB.GalleryImage -> ( String, Html Msg )
galleryRow model failed index image =
    let
        description : String
        description =
            "Rezeptbild " ++ String.fromInt (index + 1)

        imageCount : Int
        imageCount =
            case model.recipe of
                RemoteData.Success (Just recipe) ->
                    recipe.images |> Maybe.map List.length |> Maybe.withDefault 0

                _ ->
                    0
    in
    ( image.id
    , li [ class "gallery-row", id ("gallery-image-" ++ image.id), attribute "tabindex" "-1" ]
        [ span [ class "gallery-handle", attribute "aria-hidden" "true" ]
            (List.repeat 6 (span [] []))
        , if imageCount > 1 then
            div [ class "gallery-move-controls" ]
                [ button
                    [ type_ "button"
                    , class "outline"
                    , id ("move-up-" ++ image.id)
                    , attribute "aria-label" ("Bild " ++ String.fromInt (index + 1) ++ " aus " ++ (model.recipeName |> Maybe.withDefault "Rezept") ++ " nach oben verschieben")
                    , disabled (not (canMove model image.id MoveUp))
                    , onClick (MoveImage image.id MoveUp)
                    ]
                    [ span [ attribute "aria-hidden" "true" ] [ text "⌃" ] ]
                , button
                    [ type_ "button"
                    , class "outline"
                    , id ("move-down-" ++ image.id)
                    , attribute "aria-label" ("Bild " ++ String.fromInt (index + 1) ++ " aus " ++ (model.recipeName |> Maybe.withDefault "Rezept") ++ " nach unten verschieben")
                    , disabled (not (canMove model image.id MoveDown))
                    , onClick (MoveImage image.id MoveDown)
                    ]
                    [ span [ attribute "aria-hidden" "true" ] [ text "⌄" ] ]
                ]

          else
            text ""
        , if Set.member image.id failed then
            span
                [ class "gallery-thumbnail gallery-thumbnail-unavailable"
                , attribute "role" "img"
                , attribute "aria-label" description
                ]
                [ text "Vorschaubild nicht verfügbar" ]

          else
            img
                [ src image.thumbUrl
                , alt description
                , class "gallery-thumbnail"
                , on "error" (D.succeed (ThumbnailFailed image.id))
                ]
                []
        , if index == 0 then
            span [] [ text "Standardbild" ]

          else
            text ""
        , button
            [ type_ "button"
            , class "outline"
            , id ("delete-image-" ++ image.id)
            , attribute "aria-label" ("Bild " ++ String.fromInt (index + 1) ++ " aus " ++ (model.recipeName |> Maybe.withDefault "Rezept") ++ " löschen")
            , disabled (not (canDelete model image.id))
            , onClick (DeleteImage image.id)
            ]
            [ text "Löschen" ]
        ]
    )


sourceView : Model -> Session -> Html Msg
sourceView model session =
    let
        crop : Crop
        crop =
            session.crop

        percent : Int -> Int -> String
        percent value total =
            String.fromFloat (100 * toFloat value / toFloat total) ++ "%"

        handleView : ( String, String, ( String, String ) ) -> Html Msg
        handleView ( name, description, ( left, top ) ) =
            span
                [ class ("crop-handle crop-" ++ name)
                , attribute "data-handle" name
                , attribute "data-testid" ("crop-handle-" ++ name)
                , attribute "aria-label" description
                , style "left" left
                , style "top" top
                ]
                []

        shade : Int -> Int -> Int -> Int -> Html Msg
        shade x y width height =
            div
                [ class "crop-shade"
                , style "left" (percent x session.size.width)
                , style "top" (percent y session.size.height)
                , style "width" (percent width session.size.width)
                , style "height" (percent height session.size.height)
                ]
                []
    in
    div []
        [ div [ class "editor-image-area" ]
            [ div
                [ class "crop-stage"
                , attribute "data-width" (String.fromInt session.size.width)
                , attribute "data-height" (String.fromInt session.size.height)
                , attribute "data-editable" (boolString (session.previewReady && model.phase /= Saving && model.phase /= Loading))
                , attribute "aria-label" "Bild mit verschiebbarem 4:3-Zuschnitt"
                ]
                [ img [ src session.url, alt "Originalbild für den Zuschnitt", attribute "draggable" "false", attribute "data-testid" "crop-source", on "load" (D.succeed (PreviewReady session.token)), on "error" (D.succeed (PreviewFailed session.token)) ] []
                , div [ class "crop-overlay", attribute "aria-hidden" "true" ]
                    [ shade 0 0 session.size.width crop.y
                    , shade 0 (crop.y + crop.height) session.size.width (session.size.height - crop.y - crop.height)
                    , shade 0 crop.y crop.x crop.height
                    , shade (crop.x + crop.width) crop.y (session.size.width - crop.x - crop.width) crop.height
                    , div
                        [ class "crop-selection"
                        , attribute "data-handle" "move"
                        , attribute "data-testid" "crop-selection"
                        , attribute "data-x" (String.fromInt crop.x)
                        , attribute "data-y" (String.fromInt crop.y)
                        , attribute "data-width" (String.fromInt crop.width)
                        , attribute "data-height" (String.fromInt crop.height)
                        , style "left" (percent crop.x session.size.width)
                        , style "top" (percent crop.y session.size.height)
                        , style "width" (percent crop.width session.size.width)
                        , style "height" (percent crop.height session.size.height)
                        ]
                        (List.map handleView
                            [ ( "nw", "Oben links", ( "0%", "0%" ) )
                            , ( "n", "Obere Kante", ( "50%", "0%" ) )
                            , ( "ne", "Oben rechts", ( "100%", "0%" ) )
                            , ( "e", "Rechte Kante", ( "100%", "50%" ) )
                            , ( "se", "Unten rechts", ( "100%", "100%" ) )
                            , ( "s", "Untere Kante", ( "50%", "100%" ) )
                            , ( "sw", "Unten links", ( "0%", "100%" ) )
                            , ( "w", "Linke Kante", ( "0%", "50%" ) )
                            ]
                        )
                    ]
                ]
            ]
        , p [ class "crop-dimensions" ]
            [ text ("Zuschnitt: " ++ String.fromInt crop.width ++ " × " ++ String.fromInt crop.height ++ " Pixel; Position " ++ String.fromInt crop.x ++ ", " ++ String.fromInt crop.y) ]
        , if crop.width < 648 || crop.height < 486 then
            p [ class "feedback warning", attribute "role" "status" ] [ text "Dieser Zuschnitt ist kleiner als 648 × 486 Pixel und wird vergrößert. Die Bildqualität kann darunter leiden." ]

          else
            text ""
        ]
