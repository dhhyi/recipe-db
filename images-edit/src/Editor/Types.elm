module Editor.Types exposing (Drag, GalleryFeedback, GalleryFeedbackKind(..), GalleryMutation, Model, Msg(..), Phase(..), Session, canAdd, canDelete, capacityWarning, dirty, imageLimit, init)

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


type alias GalleryMutation =
    { token : Int
    , imageId : String
    , index : Int
    }


type GalleryFeedbackKind
    = DeletionSucceeded
    | ImageAlreadyAbsent
    | DeletionUnconfirmed


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
    | GotCapabilities RecipeDB.CapabilitiesModel
    | RetryGallery
    | DeleteImage String
    | DeleteConfirmed String Int Bool
    | Deleted Int RecipeDB.DeleteModel
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
    if model.phase /= Viewing || model.galleryRefreshing || model.galleryMutation /= Nothing then
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
    if model.phase /= Viewing || model.galleryRefreshing || model.galleryMutation /= Nothing || model.galleryError /= Nothing then
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
