module Editor.State exposing (update)

import Browser.Dom
import Crop exposing (Crop, Handle, Point)
import Editor.Bridge exposing (Incoming(..), command, incoming, release)
import Editor.Source as Source
import Editor.Types exposing (Model, Msg(..), Phase(..), dirty)
import File
import Json.Decode as D
import Json.Encode as E
import RecipeDB
import RemoteData
import Task


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

        GotCapabilities capabilities ->
            ( { model | capabilities = capabilities }, Cmd.none )

        GotFile file ->
            if model.phase == Viewing || model.phase == SavedOpen then
                case Source.file (File.mime file) (File.size file) of
                    Ok () ->
                        ( { model | phase = Loading, pending = Just file, token = model.token + 1, error = Nothing, drag = Nothing }
                        , command "inspect" [ ( "token", E.int (model.token + 1) ) ]
                        )

                    Err problem ->
                        ( { model | error = Just (Source.message problem), drag = Nothing }
                        , command "clear" []
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
                    , Browser.Dom.focus "upload-image" |> Task.attempt (\_ -> Focused)
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

        Focused ->
            ( model, Cmd.none )


loadFailed : Int -> Source.Problem -> Model -> ( Model, Cmd Msg )
loadFailed token problem model =
    if model.phase == Loading && token == model.token then
        ( { model
            | phase =
                if model.session == Nothing then
                    Viewing

                else
                    SavedOpen
            , pending = Nothing
            , error = Just (Source.message problem)
          }
        , release token
        )

    else
        ( model, release token )


handleEvent : Incoming -> Model -> ( Model, Cmd Msg )
handleEvent event model =
    case event of
        Metadata token size ->
            if model.phase == Loading && token == model.token && model.pending /= Nothing then
                case Source.dimensions size of
                    Ok _ ->
                        ( model, command "decode" [ ( "token", E.int token ) ] )

                    Err problem ->
                        loadFailed token problem model

            else
                ( model, release token )

        Loaded token url size actual ->
            if model.phase == Loading && token == model.token then
                case ( model.pending, Source.decoded size actual ) of
                    ( Just file, Ok crop ) ->
                        ( { model
                            | session = Just { token = token, file = file, url = url, size = size, crop = crop, saved = Nothing, previewReady = False }
                            , previous = model.session
                            , pending = Nothing
                          }
                        , Cmd.none
                        )

                    ( _, Err problem ) ->
                        loadFailed token problem model

                    _ ->
                        ( model, Cmd.none )

            else
                ( model, release token )

        LoadFailed token ->
            loadFailed token Source.Unreadable model

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
