module Editor.Types exposing (Drag, GalleryFeedback, GalleryFeedbackKind(..), GalleryMovement, GalleryMutation, Model, MoveDirection(..), Msg(..), Phase(..), Session, canAdd, canDelete, canMove, capacityWarning, dirty, imageLimit, init)

import Crop exposing (Crop, Handle, Point, Size)
import File exposing (File)
import Json.Decode as D
import RecipeDB
import RemoteData
import Set exposing (Set)


type Phase
    = Viewing
    | Loading
    | Editing
    | Saving
    | SaveFailed


type alias Session =
    { token : Int
    , file : File
    , url : String
    , size : Size
    , crop : Crop
    , previewReady : Bool
    }


type alias Drag =
    { start : Point, crop : Crop, handle : Maybe Handle }


type MoveDirection
    = MoveUp
    | MoveDown


type alias GalleryMovement =
    { direction : MoveDirection
    , fromIndex : Int
    , toIndex : Int
    , dragged : Bool
    }


type alias GalleryMutation =
    { token : Int
    , imageId : String
    , index : Int
    , movement : Maybe GalleryMovement
    , writing : Bool
    }


type GalleryFeedbackKind
    = DeletionSucceeded
    | ImageAlreadyAbsent
    | DeletionUnconfirmed
    | ReorderingSucceeded
    | ReorderingRejected
    | ReorderingUnconfirmed


type alias GalleryFeedback =
    { kind : GalleryFeedbackKind
    , message : String
    }


type alias Model =
    { recipeId : String
    , recipe : RecipeDB.RecipeModel
    , capabilities : RecipeDB.CapabilitiesModel
    , galleryToken : Int
    , galleryRefreshing : Bool
    , galleryError : Maybe String
    , galleryConfirmation : Maybe ( String, Int )
    , galleryMutation : Maybe GalleryMutation
    , galleryDrag : Maybe ( String, Int )
    , galleryPreview : Maybe (List RecipeDB.GalleryImage)
    , pendingGallery : Maybe ( Int, RecipeDB.RecipeModel )
    , mutationToken : Int
    , galleryFeedback : Maybe GalleryFeedback
    , recipeName : Maybe String
    , failedThumbnails : Set String
    , phase : Phase
    , session : Maybe Session
    , pending : Maybe File
    , token : Int
    , drag : Maybe Drag
    , error : Maybe String
    , savedFeedback : Bool
    , focusAfterCancel : Bool
    }


type Msg
    = GotRecipe Int RecipeDB.RecipeModel
    | ApplyGallery Int
    | GotCapabilities RecipeDB.CapabilitiesModel
    | RetryGallery
    | MoveImage String MoveDirection
    | DeleteImage String
    | DeleteConfirmed String Int Bool
    | Deleted Int RecipeDB.DeleteModel
    | Reordered Int RecipeDB.ReorderModel
    | ThumbnailFailed String
    | GotFile File
    | Bridge D.Value
    | PreviewReady Int
    | PreviewFailed Int
    | Save
    | Uploaded Int RecipeDB.UploadModel
    | Close
    | Focused


init : String -> Model
init recipeId =
    { recipeId = recipeId
    , recipe = RemoteData.Loading
    , capabilities = RemoteData.Loading
    , galleryToken = 0
    , galleryRefreshing = True
    , galleryError = Nothing
    , galleryConfirmation = Nothing
    , galleryMutation = Nothing
    , galleryDrag = Nothing
    , galleryPreview = Nothing
    , pendingGallery = Nothing
    , mutationToken = 0
    , galleryFeedback = Nothing
    , recipeName = Nothing
    , failedThumbnails = Set.empty
    , phase = Viewing
    , session = Nothing
    , pending = Nothing
    , token = 0
    , drag = Nothing
    , error = Nothing
    , savedFeedback = False
    , focusAfterCancel = False
    }


dirty : Model -> Bool
dirty model =
    model.phase /= Loading && model.session /= Nothing


imageLimit : Int
imageLimit =
    10


capacityWarning : Maybe (List RecipeDB.GalleryImage) -> Maybe String
capacityWarning images =
    case images of
        Just entries ->
            if List.length entries >= imageLimit then
                Just "Dieses Rezept hat bereits die maximal erlaubten zehn Bilder."

            else
                Nothing

        Nothing ->
            Nothing


canAdd : Model -> Bool
canAdd model =
    if model.phase /= Viewing || model.galleryRefreshing || model.galleryMutation /= Nothing || model.galleryDrag /= Nothing || model.galleryError /= Nothing then
        False

    else
        case ( model.capabilities, model.recipe ) of
            ( RemoteData.Success capabilities, RemoteData.Success (Just recipe) ) ->
                capabilities.canManageImages
                    && (recipe.images |> Maybe.map (\entries -> List.length entries < imageLimit) |> Maybe.withDefault False)

            _ ->
                False


canDelete : Model -> String -> Bool
canDelete model imageId =
    if model.phase /= Viewing || model.galleryRefreshing || model.galleryMutation /= Nothing || model.galleryDrag /= Nothing || model.galleryError /= Nothing then
        False

    else
        case ( model.capabilities, model.recipe ) of
            ( RemoteData.Success capabilities, RemoteData.Success (Just recipe) ) ->
                capabilities.canManageImages
                    && (recipe.images
                            |> Maybe.map (List.any (.id >> (==) imageId))
                            |> Maybe.withDefault False
                       )

            _ ->
                False


canMove : Model -> String -> MoveDirection -> Bool
canMove model imageId direction =
    if model.phase /= Viewing || model.galleryRefreshing || model.galleryMutation /= Nothing || model.galleryDrag /= Nothing || model.galleryError /= Nothing then
        False

    else
        case ( model.capabilities, model.recipe ) of
            ( RemoteData.Success capabilities, RemoteData.Success (Just recipe) ) ->
                if not capabilities.canManageImages then
                    False

                else
                    recipe.images
                        |> Maybe.map
                            (\images ->
                                case imagePosition imageId images of
                                    Just index ->
                                        case direction of
                                            MoveUp ->
                                                index > 0

                                            MoveDown ->
                                                index < List.length images - 1

                                    Nothing ->
                                        False
                            )
                        |> Maybe.withDefault False

            _ ->
                False


imagePosition : String -> List RecipeDB.GalleryImage -> Maybe Int
imagePosition imageId images =
    images
        |> List.indexedMap Tuple.pair
        |> List.filter (Tuple.second >> .id >> (==) imageId)
        |> List.head
        |> Maybe.map Tuple.first
