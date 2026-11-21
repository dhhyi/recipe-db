module Editor.State exposing (update)

import Browser.Dom
import Crop exposing (Crop, Handle, Point)
import Editor.Bridge exposing (Incoming(..), command, incoming, release)
import Editor.Source as Source
import Editor.Types exposing (GalleryFeedback, GalleryFeedbackKind(..), GalleryMovement, GalleryMutation, Model, MoveDirection(..), Msg(..), Phase(..), canAdd, canDelete, canMove, dirty)
import File
import Json.Decode as D
import Json.Encode as E
import RecipeDB
import RemoteData
import Set
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
            , ( "saving", E.bool (next.phase == Saving || next.galleryMutation /= Nothing) )
            ]
        ]
    )


step : Msg -> Model -> ( Model, Cmd Msg )
step msg model =
    case msg of
        GotRecipe token recipe ->
            if model.phase == Viewing && model.galleryRefreshing && token == model.galleryToken && model.pendingGallery == Nothing then
                if shouldAnimateGallery model recipe then
                    ( { model | pendingGallery = Just ( token, recipe ) }
                    , command "transition-gallery" [ ( "token", E.int token ) ]
                    )

                else
                    applyGallery model recipe

            else
                ( model, Cmd.none )

        ApplyGallery token ->
            case model.pendingGallery of
                Just ( pendingToken, recipe ) ->
                    if token == pendingToken && token == model.galleryToken && model.phase == Viewing && model.galleryRefreshing then
                        applyGallery { model | pendingGallery = Nothing } recipe

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        GotCapabilities capabilities ->
            ( { model | capabilities = capabilities }, Cmd.none )

        RetryGallery ->
            if model.phase == Viewing && not model.galleryRefreshing then
                if model.galleryMutation == Nothing then
                    loadGallery model

                else
                    reconcileGallery model

            else
                ( model, Cmd.none )

        MoveImage imageId direction ->
            if canMove model imageId direction then
                case ( currentImages model, imageIndex model imageId ) of
                    ( Just images, Just index ) ->
                        let
                            targetIndex : Int
                            targetIndex =
                                moveTarget direction index

                            reordered : List RecipeDB.GalleryImage
                            reordered =
                                swapImages index targetIndex images

                            token : Int
                            token =
                                model.mutationToken + 1

                            movement : GalleryMovement
                            movement =
                                { direction = direction, fromIndex = index, toIndex = targetIndex }

                            mutation : GalleryMutation
                            mutation =
                                { token = token, imageId = imageId, index = targetIndex, movement = Just movement, writing = True }
                        in
                        ( { model
                            | galleryMutation = Just mutation
                            , mutationToken = token
                            , galleryFeedback = Nothing
                            , savedFeedback = False
                          }
                        , Cmd.batch
                            [ RecipeDB.makeReorderImagesRequest model.recipeId (List.map .id reordered) (Reordered token)
                            , focusWithoutScroll "editor-status"
                            ]
                        )

                    _ ->
                        ( model, Cmd.none )

            else
                ( model, Cmd.none )

        DeleteImage imageId ->
            if model.galleryConfirmation == Nothing && canDelete model imageId then
                case ( currentImages model, imageIndex model imageId ) of
                    ( Just images, Just _ ) ->
                        ( { model | galleryConfirmation = Just ( imageId, model.galleryToken ) }
                        , command "confirm-delete"
                            [ ( "imageId", E.string imageId )
                            , ( "session", E.int model.galleryToken )
                            , ( "message", E.string (deleteConfirmation images imageId) )
                            ]
                        )

                    _ ->
                        ( model, Cmd.none )

            else
                ( model, Cmd.none )

        DeleteConfirmed imageId session accepted ->
            case model.galleryConfirmation of
                Just ( pendingId, pendingSession ) ->
                    if pendingId /= imageId || pendingSession /= session then
                        ( model, Cmd.none )

                    else
                        let
                            cleared : Model
                            cleared =
                                { model | galleryConfirmation = Nothing }
                        in
                        if accepted && session == model.galleryToken && canDelete cleared imageId then
                            startGalleryDeletion cleared imageId

                        else
                            ( cleared, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        Deleted token response ->
            case model.galleryMutation of
                Just mutation ->
                    if token /= mutation.token || mutation.movement /= Nothing || not mutation.writing || model.galleryRefreshing then
                        ( model, Cmd.none )

                    else
                        let
                            feedback : GalleryFeedback
                            feedback =
                                case response of
                                    RemoteData.Success True ->
                                        { kind = DeletionSucceeded
                                        , message = "Bild gelöscht."
                                        }

                                    RemoteData.Success False ->
                                        { kind = ImageAlreadyAbsent
                                        , message = "Das Bild war bereits entfernt."
                                        }

                                    RemoteData.Failure error ->
                                        { kind = DeletionUnconfirmed
                                        , message = error ++ " Der aktuelle Stand wird neu geladen."
                                        }

                                    _ ->
                                        { kind = DeletionUnconfirmed
                                        , message = "Die Löschung konnte nicht bestätigt werden. Der aktuelle Stand wird neu geladen."
                                        }

                            next : Model
                            next =
                                { model
                                    | galleryFeedback = Just feedback
                                    , galleryMutation = Just { mutation | writing = False }
                                }

                            ( refreshing, request ) =
                                reconcileGallery next
                        in
                        ( refreshing, Cmd.batch [ request, focusWithoutScroll "editor-status" ] )

                Nothing ->
                    ( model, Cmd.none )

        Reordered token response ->
            case model.galleryMutation of
                Just mutation ->
                    if token /= mutation.token || mutation.movement == Nothing || not mutation.writing || model.galleryRefreshing then
                        ( model, Cmd.none )

                    else
                        let
                            feedback : GalleryFeedback
                            feedback =
                                case response of
                                    RemoteData.Success RecipeDB.ReorderConfirmed ->
                                        { kind = ReorderingSucceeded
                                        , message = "Reihenfolge gespeichert. Die aktuelle Position wird geladen."
                                        }

                                    RemoteData.Success (RecipeDB.ReorderRejected message) ->
                                        { kind = ReorderingRejected, message = message }

                                    RemoteData.Success (RecipeDB.ReorderUnconfirmed message) ->
                                        { kind = ReorderingUnconfirmed, message = message }

                                    RemoteData.Failure message ->
                                        { kind = ReorderingUnconfirmed
                                        , message = message
                                        }

                                    _ ->
                                        { kind = ReorderingUnconfirmed
                                        , message = "Die Änderung der Bildreihenfolge konnte nicht bestätigt werden. Der aktuelle Stand wird neu geladen."
                                        }

                            next : Model
                            next =
                                { model
                                    | galleryFeedback = Just feedback
                                    , galleryMutation = Just { mutation | writing = False }
                                }

                            ( refreshing, request ) =
                                reconcileGallery next
                        in
                        ( refreshing, Cmd.batch [ request, focusWithoutScroll "editor-status" ] )

                Nothing ->
                    ( model, Cmd.none )

        ThumbnailFailed id ->
            if model.phase == Viewing && model.recipe /= RemoteData.Loading then
                ( { model | failedThumbnails = Set.insert id model.failedThumbnails }, Cmd.none )

            else
                ( model, Cmd.none )

        GotFile file ->
            if canAdd model then
                case Source.file (File.mime file) (File.size file) of
                    Ok () ->
                        ( { model | phase = Loading, pending = Just file, token = model.token + 1, error = Nothing, galleryFeedback = Nothing, drag = Nothing }
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
                        ( { model | session = Just { session | previewReady = True }, phase = Editing, savedFeedback = False, error = Nothing }
                        , Cmd.none
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
                            | session = Nothing
                            , phase = Viewing
                            , error = Just "Das Vorschaubild konnte nicht angezeigt werden. Bitte eine andere JPEG- oder PNG-Datei auswählen."
                            , pending = Nothing
                            , drag = Nothing
                          }
                        , Cmd.batch [ release token, focus "upload-image" ]
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
                        , RecipeDB.makeUploadRequest model.recipeId session.file session.crop (Uploaded session.token)
                        )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        Uploaded token response ->
            case model.session of
                Just session ->
                    if model.phase /= Saving || token /= session.token then
                        ( model, Cmd.none )

                    else
                        case response of
                            RemoteData.Success _ ->
                                returnToGallery True model session.token

                            RemoteData.Failure error ->
                                ( { model
                                    | phase = SaveFailed
                                    , error =
                                        Just
                                            (if error == "authentication-required" || error == "forbidden" then
                                                error

                                             else
                                                error ++ " Der Zuschnitt bleibt für einen erneuten Speicherversuch erhalten."
                                            )
                                  }
                                , Cmd.none
                                )

                            _ ->
                                ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        Close ->
            case model.session of
                Just session ->
                    if model.phase == Saving || model.phase == Loading then
                        ( model, Cmd.none )

                    else
                        returnToGallery False model session.token

                Nothing ->
                    ( model, Cmd.none )

        Focused ->
            ( model, Cmd.none )


shouldAnimateGallery : Model -> RecipeDB.RecipeModel -> Bool
shouldAnimateGallery model recipe =
    case ( model.galleryMutation, model.galleryFeedback, recipe ) of
        ( Just mutation, Just feedback, RemoteData.Success (Just data) ) ->
            case ( currentImages model, data.images ) of
                ( Just oldImages, Just newImages ) ->
                    (feedback.kind
                        == ReorderingSucceeded
                        && mutation.movement
                        /= Nothing
                        || feedback.kind
                        == DeletionSucceeded
                        && mutation.movement
                        == Nothing
                    )
                        && List.map .id oldImages
                        /= List.map .id newImages

                _ ->
                    False

        _ ->
            False


applyGallery : Model -> RecipeDB.RecipeModel -> ( Model, Cmd Msg )
applyGallery model recipe =
    let
        readError : Maybe String
        readError =
            case recipe of
                RemoteData.Failure _ ->
                    Just "Rezeptbilder konnten nicht geladen werden."

                RemoteData.Loading ->
                    Just "Rezeptbilder konnten nicht geladen werden."

                RemoteData.Success (Just data) ->
                    if data.images == Nothing then
                        Just "Rezeptbilder konnten nicht geladen werden."

                    else
                        Nothing

                _ ->
                    Nothing

        displayedRecipe : RecipeDB.RecipeModel
        displayedRecipe =
            if readError /= Nothing && model.galleryMutation /= Nothing then
                model.recipe

            else
                recipe

        next : Model
        next =
            { model
                | recipe = displayedRecipe
                , galleryRefreshing = False
                , galleryError = readError
                , galleryFeedback = galleryFeedbackAfterRead model readError displayedRecipe
                , galleryMutation =
                    if readError == Nothing then
                        Nothing

                    else
                        model.galleryMutation
                , recipeName =
                    case displayedRecipe of
                        RemoteData.Success (Just data) ->
                            Just data.name

                        _ ->
                            model.recipeName
                , focusAfterCancel = False
            }

        focusCommand : Cmd Msg
        focusCommand =
            case ( model.focusAfterCancel, model.galleryMutation, readError ) of
                ( True, _, Nothing ) ->
                    if canAdd next then
                        focus "upload-image"

                    else
                        Cmd.none

                ( False, Just mutation, Nothing ) ->
                    focusAfterMutation next mutation

                _ ->
                    Cmd.none
    in
    ( next, focusCommand )


loadGallery : Model -> ( Model, Cmd Msg )
loadGallery model =
    let
        token : Int
        token =
            model.galleryToken + 1
    in
    ( { model
        | recipe = RemoteData.Loading
        , galleryToken = token
        , galleryRefreshing = True
        , galleryError = Nothing
        , galleryConfirmation = Nothing
        , galleryFeedback =
            if model.galleryMutation == Nothing then
                Nothing

            else
                model.galleryFeedback
        , error = Nothing
        , failedThumbnails = Set.empty
      }
    , RecipeDB.makeRecipeRequest model.recipeId (GotRecipe token)
    )


reconcileGallery : Model -> ( Model, Cmd Msg )
reconcileGallery model =
    let
        token : Int
        token =
            model.galleryToken + 1
    in
    ( { model
        | galleryToken = token
        , galleryRefreshing = True
        , galleryError = Nothing
        , galleryConfirmation = Nothing
        , failedThumbnails = Set.empty
      }
    , RecipeDB.makeRecipeRequest model.recipeId (GotRecipe token)
    )


returnToGallery : Bool -> Model -> Int -> ( Model, Cmd Msg )
returnToGallery saved model token =
    let
        ( next, request ) =
            loadGallery
                { model
                    | phase = Viewing
                    , session = Nothing
                    , pending = Nothing
                    , drag = Nothing
                    , token = model.token + 1
                    , savedFeedback = saved
                    , focusAfterCancel = not saved
                    , galleryMutation = Nothing
                    , galleryConfirmation = Nothing
                    , galleryError = Nothing
                }
    in
    ( next, Cmd.batch [ release token, request ] )


focus : String -> Cmd Msg
focus target =
    Browser.Dom.focus target |> Task.attempt (\_ -> Focused)


focusWithoutScroll : String -> Cmd Msg
focusWithoutScroll target =
    command "focus-without-scroll" [ ( "id", E.string target ) ]


loadFailed : Int -> Source.Problem -> Model -> ( Model, Cmd Msg )
loadFailed token problem model =
    if model.phase == Loading && token == model.token then
        ( { model
            | phase = Viewing
            , session = Nothing
            , pending = Nothing
            , error = Just (Source.message problem)
          }
        , Cmd.batch [ release token, focus "upload-image" ]
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
            if model.phase == Loading && token == model.token && model.pending /= Nothing then
                case ( model.pending, Source.decoded size actual ) of
                    ( Just file, Ok crop ) ->
                        ( { model
                            | session = Just { token = token, file = file, url = url, size = size, crop = crop, previewReady = False }
                            , pending = Nothing
                          }
                        , Cmd.none
                        )

                    ( _, Err problem ) ->
                        loadFailed token problem model

                    _ ->
                        ( model, Cmd.none )

            else if model.session |> Maybe.map (.token >> (==) token) |> Maybe.withDefault False then
                ( model, Cmd.none )

            else
                ( model, release token )

        LoadFailed token ->
            loadFailed token Source.Unreadable model

        DeleteConfirmation imageId session accepted ->
            step (DeleteConfirmed imageId session accepted) model

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
                                        , phase = Editing
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


currentImages : Model -> Maybe (List RecipeDB.GalleryImage)
currentImages model =
    case model.recipe of
        RemoteData.Success (Just recipe) ->
            recipe.images

        _ ->
            Nothing


imageIndex : Model -> String -> Maybe Int
imageIndex model imageId =
    currentImages model
        |> Maybe.andThen
            (List.indexedMap Tuple.pair
                >> List.filter (Tuple.second >> .id >> (==) imageId)
                >> List.head
                >> Maybe.map Tuple.first
            )


deleteConfirmation : List RecipeDB.GalleryImage -> String -> String
deleteConfirmation images imageId =
    case imageIndexIn images imageId of
        Just 0 ->
            if List.length images == 1 then
                "Das einzige Bild löschen? Dieses Rezept hat danach kein Bild."

            else
                "Das erste Bild löschen? Das nächste Bild wird dann zum Standardbild."

        _ ->
            "Dieses Bild löschen?"


imageIndexIn : List RecipeDB.GalleryImage -> String -> Maybe Int
imageIndexIn images imageId =
    images
        |> List.indexedMap Tuple.pair
        |> List.filter (Tuple.second >> .id >> (==) imageId)
        |> List.head
        |> Maybe.map Tuple.first


startGalleryDeletion : Model -> String -> ( Model, Cmd Msg )
startGalleryDeletion model imageId =
    case imageIndex model imageId of
        Just index ->
            let
                token : Int
                token =
                    model.mutationToken + 1

                mutation : GalleryMutation
                mutation =
                    { token = token, imageId = imageId, index = index, movement = Nothing, writing = True }
            in
            ( { model
                | galleryMutation = Just mutation
                , mutationToken = token
                , galleryFeedback = Nothing
                , savedFeedback = False
              }
            , Cmd.batch
                [ RecipeDB.makeDeleteImageRequest model.recipeId imageId (Deleted token)
                , focusWithoutScroll "editor-status"
                ]
            )

        Nothing ->
            ( model, Cmd.none )


focusAfterMutation : Model -> GalleryMutation -> Cmd Msg
focusAfterMutation model mutation =
    case mutation.movement of
        Just movement ->
            focusAfterReordering model mutation movement

        Nothing ->
            focusAfterDeletion model mutation


focusAfterDeletion : Model -> GalleryMutation -> Cmd Msg
focusAfterDeletion model mutation =
    let
        remaining : List RecipeDB.GalleryImage
        remaining =
            currentImages model
                |> Maybe.withDefault []
                |> List.filter (.id >> (/=) mutation.imageId)

        focusRow : Maybe RecipeDB.GalleryImage -> Cmd Msg
        focusRow image =
            case image of
                Just entry ->
                    if canDelete model entry.id then
                        focusWithoutScroll ("delete-image-" ++ entry.id)

                    else
                        focusWithoutScroll "gallery-heading"

                Nothing ->
                    if canAdd model then
                        focusWithoutScroll "upload-image"

                    else
                        focusWithoutScroll "gallery-heading"

        next : Maybe RecipeDB.GalleryImage
        next =
            List.drop mutation.index remaining |> List.head
    in
    case next of
        Just image ->
            focusRow (Just image)

        Nothing ->
            focusRow (List.take mutation.index remaining |> List.reverse |> List.head)


focusAfterReordering : Model -> GalleryMutation -> GalleryMovement -> Cmd Msg
focusAfterReordering model mutation movement =
    let
        focusDirection : MoveDirection -> Cmd Msg
        focusDirection direction =
            focusWithoutScroll
                ((case direction of
                    MoveUp ->
                        "move-up-"

                    MoveDown ->
                        "move-down-"
                 )
                    ++ mutation.imageId
                )
    in
    if canMove model mutation.imageId movement.direction then
        focusDirection movement.direction

    else
        let
            opposite : MoveDirection
            opposite =
                case movement.direction of
                    MoveUp ->
                        MoveDown

                    MoveDown ->
                        MoveUp
        in
        if canMove model mutation.imageId opposite then
            focusDirection opposite

        else
            focusWithoutScroll ("gallery-image-" ++ mutation.imageId)


galleryFeedbackAfterRead : Model -> Maybe String -> RecipeDB.RecipeModel -> Maybe GalleryFeedback
galleryFeedbackAfterRead model readError recipe =
    case ( model.galleryMutation, model.galleryFeedback, readError ) of
        ( Just mutation, Just feedback, Just _ ) ->
            if mutation.movement /= Nothing && feedback.kind == ReorderingSucceeded then
                Just { feedback | message = "Reihenfolge gespeichert. Die aktuelle Position konnte nicht geladen werden." }

            else
                Just feedback

        ( Just mutation, Just feedback, Nothing ) ->
            if mutation.movement /= Nothing && feedback.kind == ReorderingSucceeded then
                Just { feedback | message = reorderingSuccessMessage recipe mutation }

            else
                Just feedback

        _ ->
            model.galleryFeedback


reorderingSuccessMessage : RecipeDB.RecipeModel -> GalleryMutation -> String
reorderingSuccessMessage recipe mutation =
    case recipe of
        RemoteData.Success (Just data) ->
            case data.images |> Maybe.andThen (\images -> imageIndexIn images mutation.imageId) of
                Just index ->
                    if index == 0 then
                        "Bild an Position 1 verschoben und als Standardbild festgelegt."

                    else
                        "Bild an Position " ++ String.fromInt (index + 1) ++ " verschoben."

                Nothing ->
                    "Reihenfolge gespeichert. Das Bild ist im aktuellen Stand nicht mehr vorhanden."

        _ ->
            "Reihenfolge gespeichert. Die aktuelle Position konnte nicht geladen werden."


moveTarget : MoveDirection -> Int -> Int
moveTarget direction index =
    case direction of
        MoveUp ->
            index - 1

        MoveDown ->
            index + 1


swapImages : Int -> Int -> List RecipeDB.GalleryImage -> List RecipeDB.GalleryImage
swapImages fromIndex toIndex images =
    case ( List.drop fromIndex images |> List.head, List.drop toIndex images |> List.head ) of
        ( Just fromImage, Just toImage ) ->
            images
                |> List.indexedMap
                    (\index image ->
                        if index == fromIndex then
                            toImage

                        else if index == toIndex then
                            fromImage

                        else
                            image
                    )

        _ ->
            images
