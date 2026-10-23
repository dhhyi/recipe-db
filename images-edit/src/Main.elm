port module Main exposing (main)

import Browser
import Crop exposing (Crop, Handle, Point, Size)
import File exposing (File)
import Html exposing (Html, button, div, h1, img, input, label, p, span, text)
import Html.Attributes exposing (accept, alt, attribute, class, disabled, for, id, src, style, type_)
import Html.Events exposing (on, onClick)
import Json.Decode as D
import Json.Encode as E
import List
import RecipeDB
import RemoteData


port editorCommand : E.Value -> Cmd msg


port editorEvent : (D.Value -> msg) -> Sub msg


type Phase
    = Viewing
    | Loading
    | Editing
    | Saving
    | SaveFailed
    | SavedOpen


type alias Session =
    { token : Int
    , file : File
    , url : String
    , size : Size
    , crop : Crop
    , saved : Maybe Crop
    , previewReady : Bool
    }


type alias Drag =
    { start : Point, crop : Crop, handle : Maybe Handle }


type alias Model =
    { recipeId : String
    , recipe : RecipeDB.RecipeModel
    , latestUrl : Maybe String
    , phase : Phase
    , session : Maybe Session
    , previous : Maybe Session
    , pending : Maybe File
    , token : Int
    , drag : Maybe Drag
    , error : Maybe String
    , savedFeedback : Bool
    }


type Msg
    = GotRecipe RecipeDB.RecipeModel
    | GotFile File
    | Bridge D.Value
    | PreviewReady Int
    | PreviewFailed Int
    | Save
    | Uploaded Int Crop RecipeDB.UploadModel
    | Close
    | Back


type Incoming
    = Loaded Int String Int Int
    | LoadFailed Int String
    | Pointer String String Point { width : Float, height : Float }
    | EndPointer


main : Program { recipeId : String } Model Msg
main =
    Browser.element
        { init =
            \flags ->
                ( { recipeId = flags.recipeId
                  , recipe = RemoteData.Loading
                  , latestUrl = Nothing
                  , phase = Viewing
                  , session = Nothing
                  , previous = Nothing
                  , pending = Nothing
                  , token = 0
                  , drag = Nothing
                  , error = Nothing
                  , savedFeedback = False
                  }
                , RecipeDB.makeRecipeRequest flags.recipeId GotRecipe
                )
        , update = update
        , view = view
        , subscriptions = \_ -> editorEvent Bridge
        }


command : String -> List ( String, E.Value ) -> Cmd Msg
command action fields =
    editorCommand (E.object (( "action", E.string action ) :: fields))


release : Int -> Cmd Msg
release token =
    command "release" [ ( "token", E.int token ) ]


dirty : Model -> Bool
dirty model =
    if model.phase == Loading then
        False

    else
        case model.session of
            Just session ->
                session.saved /= Just session.crop

            Nothing ->
                False


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        ( next, effect ) =
            step msg model
    in
    ( next
    , Cmd.batch
        [ effect
        , command "guard"
            [ ( "dirty", E.bool (dirty next || next.phase == Saving) )
            , ( "saving", E.bool (next.phase == Saving) )
            ]
        ]
    )


step : Msg -> Model -> ( Model, Cmd Msg )
step msg model =
    case msg of
        GotRecipe recipe ->
            ( { model | recipe = recipe }, Cmd.none )

        GotFile file ->
            if model.phase == Viewing || model.phase == SavedOpen then
                ( { model | phase = Loading, pending = Just file, token = model.token + 1, error = Nothing, drag = Nothing }
                , command "load" [ ( "token", E.int (model.token + 1) ) ]
                )

            else
                ( model, Cmd.none )

        Bridge value ->
            case D.decodeValue incoming value of
                Ok event ->
                    handleEvent event model

                Err _ ->
                    ( model, Cmd.none )

        PreviewReady token ->
            case model.session of
                Just session ->
                    if session.token == token && not session.previewReady && model.phase == Loading then
                        ( { model | session = Just { session | previewReady = True }, previous = Nothing, phase = Editing, savedFeedback = False, error = Nothing }
                        , model.previous |> Maybe.map (.token >> release) |> Maybe.withDefault Cmd.none
                        )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        PreviewFailed token ->
            case model.session of
                Just session ->
                    if session.token /= token then
                        ( model, Cmd.none )

                    else if model.phase == Loading then
                        ( { model
                            | session = model.previous
                            , previous = Nothing
                            , phase =
                                if model.previous == Nothing then
                                    Viewing

                                else
                                    SavedOpen
                            , error = Just "Das Vorschaubild konnte nicht angezeigt werden. Bitte eine andere JPEG- oder PNG-Datei auswählen."
                            , pending = Nothing
                            , drag = Nothing
                          }
                        , release token
                        )

                    else
                        ( { model
                            | session = Just { session | previewReady = False }
                            , error = Just "Das Vorschaubild konnte nicht angezeigt werden. Speichern ist deaktiviert. Bitte das lokale Bild schließen und erneut auswählen."
                            , drag = Nothing
                          }
                        , Cmd.none
                        )

                Nothing ->
                    ( model, Cmd.none )

        Save ->
            case model.session of
                Just session ->
                    if session.previewReady && dirty model && (model.phase == Editing || model.phase == SaveFailed) then
                        ( { model | phase = Saving, error = Nothing, drag = Nothing }
                        , RecipeDB.makeUploadRequest model.recipeId session.file session.crop (Uploaded session.token session.crop)
                        )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        Uploaded token crop response ->
            case model.session of
                Just session ->
                    if model.phase /= Saving || token /= session.token then
                        ( model, Cmd.none )

                    else
                        case response of
                            RemoteData.Success image ->
                                ( { model
                                    | phase = SavedOpen
                                    , session = Just { session | saved = Just crop }
                                    , latestUrl = Just image.url
                                    , error =
                                        if session.previewReady then
                                            Nothing

                                        else
                                            model.error
                                    , savedFeedback = True
                                  }
                                , Cmd.none
                                )

                            RemoteData.Failure error ->
                                ( { model | phase = SaveFailed, error = Just (error ++ " Das bisherige Bild bleibt erhalten.") }, Cmd.none )

                            _ ->
                                ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        Close ->
            if model.phase == Saving || model.phase == Loading then
                ( model, Cmd.none )

            else
                ( { model | phase = Viewing, session = Nothing, previous = Nothing, drag = Nothing, error = Nothing, token = model.token + 1, savedFeedback = False }
                , Cmd.batch
                    [ model.session |> Maybe.map (.token >> release) |> Maybe.withDefault Cmd.none
                    , command "focus" [ ( "id", E.string "upload-image" ) ]
                    ]
                )

        Back ->
            if model.phase == Saving then
                ( model, Cmd.none )

            else
                ( model
                , command "navigate"
                    [ ( "url", E.string ("/recipe/" ++ model.recipeId) )
                    , ( "dirty", E.bool (dirty model) )
                    ]
                )


incoming : D.Decoder Incoming
incoming =
    D.field "kind" D.string
        |> D.andThen
            (\kind ->
                case kind of
                    "loaded" ->
                        D.map4 Loaded (D.field "token" D.int) (D.field "url" D.string) (D.field "width" D.int) (D.field "height" D.int)

                    "failed" ->
                        D.map2 LoadFailed (D.field "token" D.int) (D.field "error" D.string)

                    "pointer" ->
                        D.map4 Pointer
                            (D.field "event" D.string)
                            (D.field "handle" D.string)
                            (D.map2 Point (D.field "x" D.float) (D.field "y" D.float))
                            (D.map2 (\width height -> { width = width, height = height }) (D.field "displayWidth" D.float) (D.field "displayHeight" D.float))

                    "end" ->
                        D.succeed EndPointer

                    _ ->
                        D.fail "Unbekanntes Editorereignis"
            )


handleEvent : Incoming -> Model -> ( Model, Cmd Msg )
handleEvent event model =
    case event of
        Loaded token url width height ->
            if model.phase == Loading && token == model.token then
                case ( model.pending, Crop.centered { width = width, height = height } ) of
                    ( Just file, Just crop ) ->
                        ( { model
                            | session = Just { token = token, file = file, url = url, size = { width = width, height = height }, crop = crop, saved = Nothing, previewReady = False }
                            , previous = model.session
                            , pending = Nothing
                          }
                        , Cmd.none
                        )

                    _ ->
                        handleEvent (LoadFailed token "Das Bild ist zu klein. Mindestens 300 × 225 Pixel im 4:3-Zuschnitt sind erforderlich.") model

            else
                ( model, release token )

        LoadFailed token error ->
            if model.phase == Loading && token == model.token then
                ( { model
                    | phase =
                        if model.session == Nothing then
                            Viewing

                        else
                            SavedOpen
                    , pending = Nothing
                    , error = Just error
                  }
                , release token
                )

            else
                ( model, release token )

        EndPointer ->
            ( { model | drag = Nothing }, Cmd.none )

        Pointer eventName handle displayPoint display ->
            case model.session of
                Just session ->
                    if model.phase == Saving || model.phase == Loading || not session.previewReady then
                        ( model, Cmd.none )

                    else if eventName == "start" then
                        ( { model | drag = Just { start = Crop.fromDisplay session.size display displayPoint, crop = session.crop, handle = lookupHandle handle } }, Cmd.none )

                    else
                        case model.drag of
                            Just drag ->
                                let
                                    point : Point
                                    point =
                                        Crop.fromDisplay session.size display displayPoint

                                    delta : Point
                                    delta =
                                        { x = point.x - drag.start.x, y = point.y - drag.start.y }

                                    crop : Crop
                                    crop =
                                        case drag.handle of
                                            Just resizeHandle ->
                                                Crop.resize session.size resizeHandle delta drag.crop

                                            Nothing ->
                                                Crop.move session.size delta drag.crop
                                in
                                if crop == session.crop then
                                    ( model, Cmd.none )

                                else
                                    ( { model
                                        | session = Just { session | crop = crop }
                                        , phase =
                                            if session.saved == Just crop then
                                                SavedOpen

                                            else
                                                Editing
                                        , error = Nothing
                                        , savedFeedback = False
                                      }
                                    , Cmd.none
                                    )

                            Nothing ->
                                ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )


lookupHandle : String -> Maybe Handle
lookupHandle name =
    Crop.handles |> List.filter (Tuple.first >> (==) name) |> List.head |> Maybe.map Tuple.second


view : Model -> Html Msg
view model =
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
                p [ attribute "role" "alert", class "feedback error" ] [ text error ]

            Nothing ->
                text ""
        , p [ attribute "role" "status", attribute "aria-live" "polite" ] [ text (status model) ]
        , case model.session of
            Just session ->
                sourceView model session

            Nothing ->
                savedView model
        , div [ class "editor-actions" ]
            [ label [ for "upload-image" ] [ text "JPEG- oder PNG-Bild auswählen (maximal 10 MiB)" ]
            , input
                [ id "upload-image"
                , type_ "file"
                , accept "image/jpeg,image/png,.jpg,.jpeg,.png"
                , disabled (not canSelect)
                , on "change" (D.map GotFile fileDecoder)
                ]
                []
            , if model.session /= Nothing || model.phase == Loading then
                div [ class "editor-buttons" ]
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
