module Editor.View exposing (view)

import Crop exposing (Crop)
import Editor.Types exposing (Model, Msg(..), Phase(..), Session, dirty)
import File exposing (File)
import Html exposing (Html, a, button, div, h1, img, input, label, p, span, text)
import Html.Attributes exposing (accept, alt, attribute, class, disabled, for, href, id, src, style, type_)
import Html.Events exposing (on, onClick)
import Json.Decode as D
import RemoteData


view : Model -> Html Msg
view model =
    case model.capabilities of
        RemoteData.Success capabilities ->
            if capabilities.canManageImages then
                editorView model

            else if capabilities.role == "anonymous" then
                accessPage model "Anmeldung erforderlich" "Zum Verwalten von Bildern ist eine Anmeldung erforderlich." True

            else
                accessPage model "Keine Berechtigung" "Dein Konto darf Rezeptbilder nicht verwalten." False

        RemoteData.Failure _ ->
            accessPage model "Zugriff nicht verfügbar" "Die Anmeldung konnte nicht geprüft werden." True

        _ ->
            accessPage model "Zugriff wird geprüft" "Bitte warten …" False


accessPage : Model -> String -> String -> Bool -> Html Msg
accessPage model title message signIn =
    Html.main_ [ class "image-editor" ]
        [ h1 [] [ text title ]
        , p [ attribute "role" "alert", class "feedback error" ] [ text message ]
        , if signIn then
            a [ href "/oauth2/start?rd=%2F" ] [ text "Mit Google anmelden" ]

          else
            text ""
        , a [ href ("/recipe/" ++ model.recipeId) ] [ text "Zurück zum Rezept" ]
        , a [ href "/" ] [ text "Zurück zur Übersicht" ]
        ]


editorView : Model -> Html Msg
editorView model =
    let
        title : String
        title =
            case model.recipe of
                RemoteData.Success (Just recipe) ->
                    "Bild für " ++ recipe.name ++ " bearbeiten"

                _ ->
                    "Bild bearbeiten"

        canSelect : Bool
        canSelect =
            model.phase == Viewing || model.phase == SavedOpen

        busy : Bool
        busy =
            model.phase == Saving

        fileDecoder : D.Decoder File
        fileDecoder =
            D.at [ "target", "files", "0" ] File.decoder
    in
    Html.main_ [ class "image-editor", attribute "aria-busy" (boolString (busy || model.phase == Loading)) ]
        [ h1 [] [ text title ]
        , case model.error of
            Just error ->
                errorMessage model error

            Nothing ->
                text ""
        , p [ attribute "role" "status", attribute "aria-live" "polite" ] [ text (status model) ]
        , case model.session of
            Just session ->
                sourceView model session

            Nothing ->
                savedView model
        , div [ class "editor-actions grid! gap-2 my-3" ]
            [ label [ for "upload-image" ] [ text "JPEG- oder PNG-Bild auswählen (maximal 10 MiB)" ]
            , input
                [ id "upload-image"
                , class "max-w-full"
                , type_ "file"
                , accept "image/jpeg,image/png,.jpg,.jpeg,.png"
                , disabled (not canSelect)
                , on "change" (D.map GotFile fileDecoder)
                ]
                []
            , if model.session /= Nothing || model.phase == Loading then
                div [ class "editor-buttons flex flex-wrap gap-2" ]
                    [ button [ type_ "button", disabled (not (dirty model && (model.phase == Editing || model.phase == SaveFailed) && (model.session |> Maybe.map .previewReady |> Maybe.withDefault False))), attribute "aria-busy" (boolString busy), onClick Save ]
                        [ text
                            (if busy then
                                "Speichert …"

                             else if model.phase == SaveFailed then
                                "Erneut speichern"

                             else
                                "Speichern"
                            )
                        ]
                    , button [ type_ "button", class "secondary", disabled (busy || model.phase == Loading), onClick Close ]
                        [ text
                            (if dirty model then
                                "Abbrechen"

                             else
                                "Schließen"
                            )
                        ]
                    ]

              else
                text ""
            , button [ type_ "button", class "secondary", disabled busy, attribute "aria-disabled" (boolString busy), onClick Back ] [ text "Zurück zum Rezept" ]
            ]
        ]


errorMessage : Model -> String -> Html Msg
errorMessage model error =
    case error of
        "authentication-required" ->
            div [ attribute "role" "alert", class "feedback error" ]
                [ p [] [ text "Anmeldung erforderlich oder abgelaufen." ]
                , a [ href "/oauth2/start?rd=%2F" ] [ text "Anmelden" ]
                , a [ href "/oauth2/sign_out?rd=%2F" ] [ text "Abmelden und zurück zur Übersicht" ]
                ]

        "forbidden" ->
            div [ attribute "role" "alert", class "feedback error" ]
                [ p [] [ text "Keine Berechtigung zum Verwalten dieses Bildes." ]
                , a [ href ("/recipe/" ++ model.recipeId) ] [ text "Zurück zum Rezept" ]
                ]

        _ ->
            p [ attribute "role" "alert", class "feedback error" ] [ text error ]


boolString : Bool -> String
boolString value =
    if value then
        "true"

    else
        "false"


status : Model -> String
status model =
    case model.phase of
        Viewing ->
            case model.recipe of
                RemoteData.Failure _ ->
                    "Rezept konnte nicht geladen werden."

                RemoteData.Success Nothing ->
                    "Rezept nicht gefunden."

                RemoteData.Loading ->
                    "Rezept wird geladen …"

                _ ->
                    ""

        Loading ->
            "Bild wird geprüft und geladen …"

        Editing ->
            "Ungespeicherter Zuschnitt. Verschieben Sie die Auswahl oder ziehen Sie an einem der acht Griffe."

        Saving ->
            "Bild wird gespeichert. Bitte warten …"

        SaveFailed ->
            "Der Zuschnitt bleibt für einen erneuten Speicherversuch erhalten."

        SavedOpen ->
            if model.savedFeedback then
                "Bild gespeichert. Für einen weiteren Zuschnitt bleibt das Original geöffnet."

            else
                "Keine ungespeicherten Änderungen. Das Original bleibt für weitere Zuschnitte geöffnet."


savedView : Model -> Html Msg
savedView model =
    let
        recipeUrl : Maybe String
        recipeUrl =
            case model.recipe of
                RemoteData.Success (Just recipe) ->
                    recipe.url

                _ ->
                    Nothing
    in
    case model.latestUrl |> Maybe.map Just |> Maybe.withDefault recipeUrl of
        Just url ->
            img [ src url, alt "Gespeichertes Rezeptbild", class "recipe-image" ] []

        Nothing ->
            p [] [ text "Kein Bild vorhanden." ]


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
