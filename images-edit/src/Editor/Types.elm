module Editor.Types exposing (Drag, Model, Msg(..), Phase(..), Session, dirty, init)

import Crop exposing (Crop, Handle, Point, Size)
import File exposing (File)
import Json.Decode as D
import RecipeDB
import RemoteData


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
    , capabilities : RecipeDB.CapabilitiesModel
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
    | GotCapabilities RecipeDB.CapabilitiesModel
    | GotFile File
    | Bridge D.Value
    | PreviewReady Int
    | PreviewFailed Int
    | Save
    | Uploaded Int Crop RecipeDB.UploadModel
    | Close
    | Back
    | Focused


init : String -> Model
init recipeId =
    { recipeId = recipeId
    , recipe = RemoteData.Loading
    , capabilities = RemoteData.Loading
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
