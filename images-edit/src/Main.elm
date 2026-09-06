module Main exposing (main)

import Accessibility.Role as Role
import Browser
import File exposing (File)
import Html exposing (Html, a, div, figure, h1, img, input, label, p, text)
import Html.Attributes exposing (attribute, class, for, hidden, href, id, multiple, src, type_)
import Html.Events exposing (on)
import Json.Decode as D
import Maybe.Extra exposing (toList)
import RecipeDB
import RemoteData



-- DATA


type alias Model =
    { recipeId : String
    , recipe : RecipeDB.RecipeModel
    , uploaded : RecipeDB.UploadModel
    }


type Msg
    = GotRecipeResponse RecipeDB.RecipeModel
    | GotFile File
    | GotUploadResponse RecipeDB.UploadModel


type alias Flags =
    { recipeId : String }


type Feedback
    = Success String
    | Failure String



-- LOGIC


init : Flags -> ( Model, Cmd Msg )
init { recipeId } =
    let
        initialModel : Model
        initialModel =
            { recipeId = recipeId
            , recipe = RemoteData.Loading
            , uploaded = RemoteData.NotAsked
            }

        initialCmd : Cmd Msg
        initialCmd =
            RecipeDB.makeRecipeRequest recipeId GotRecipeResponse
    in
    ( initialModel
    , initialCmd
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        newModel : Model
        newModel =
            case msg of
                GotRecipeResponse recipe ->
                    { model | recipe = recipe }

                GotFile _ ->
                    { model | uploaded = RemoteData.Loading }

                GotUploadResponse upload ->
                    { model | uploaded = upload }

        cmd : Cmd Msg
        cmd =
            case msg of
                GotRecipeResponse _ ->
                    Cmd.none

                GotFile file ->
                    RecipeDB.makeUploadRequest newModel.recipeId file GotUploadResponse

                GotUploadResponse _ ->
                    Cmd.none
    in
    ( newModel, cmd )


main : Program { recipeId : String } Model Msg
main =
    Browser.element
        { init = init
        , view = view
        , update = update
        , subscriptions = \_ -> Sub.none
        }



-- VIEW


view : Model -> Html Msg
view model =
    Html.main_ [] <|
        recipeDisplay model
            ++ toList (uploadFeedback model)
            ++ [ interactions model ]


feedback : Feedback -> Html Msg
feedback f =
    case f of
        Success message ->
            p [ class "feedback success", Role.alert ] [ text message ]

        Failure message ->
            p [ class "feedback error", Role.alert ] [ text message ]


recipeDisplay : Model -> List (Html Msg)
recipeDisplay model =
    case model.recipe of
        RemoteData.Success maybeRecipe ->
            case maybeRecipe of
                Just recipe ->
                    [ recipeHeading recipe
                    , recipeThumbnail recipe
                    ]

                Nothing ->
                    [ feedback (Failure "Rezept nicht gefunden") ]

        RemoteData.Failure _ ->
            [ feedback (Failure "Fehler beim Laden") ]

        _ ->
            []


recipeHeading : RecipeDB.RecipeData -> Html Msg
recipeHeading recipe =
    h1 [] [ text ("Bild für " ++ recipe.name ++ " bearbeiten") ]


recipeThumbnail : RecipeDB.RecipeData -> Html Msg
recipeThumbnail recipe =
    case recipe.thumbUrl of
        Just thumbUrl ->
            figure [ class "contents!" ]
                [ img [ src thumbUrl, class "recipe-thumbnail" ] []
                ]

        Nothing ->
            feedback (Failure "Kein Bild vorhanden")


uploadFeedback : Model -> Maybe (Html Msg)
uploadFeedback model =
    let
        uploadError : Html Msg
        uploadError =
            feedback (Failure "Fehler beim Hochladen")
    in
    case model.uploaded of
        RemoteData.Success True ->
            Just (feedback (Success "Bild hochgeladen"))

        RemoteData.Success False ->
            Just uploadError

        RemoteData.Failure _ ->
            Just uploadError

        _ ->
            Nothing


uploadImageButton : Model -> Html Msg
uploadImageButton model =
    let
        fileDecoder : D.Decoder File
        fileDecoder =
            D.at [ "target", "files", String.fromInt 0 ] File.decoder

        uploadLabelDefaults : List (Html.Attribute Msg)
        uploadLabelDefaults =
            [ for "upload-image", Role.button, class "mb-0!" ]

        uploadLabel : Html Msg
        uploadLabel =
            case model.uploaded of
                RemoteData.Loading ->
                    label (uploadLabelDefaults ++ [ attribute "aria-busy" "true" ]) [ text "Lade hoch..." ]

                _ ->
                    label uploadLabelDefaults [ text "Bild hochladen" ]
    in
    div [ class "contents" ]
        [ input
            [ id "upload-image"
            , type_ "file"
            , multiple False
            , on "change" (D.map GotFile fileDecoder)
            , hidden True
            ]
            []
        , uploadLabel
        ]


backToRecipeLink : Model -> Html Msg
backToRecipeLink model =
    let
        buttonText : String
        buttonText =
            case model.uploaded of
                RemoteData.Success True ->
                    "Zurück"

                _ ->
                    "Abbrechen"
    in
    a [ href ("/recipe/" ++ model.recipeId), Role.button, class "secondary" ] [ text buttonText ]


interactions : Model -> Html Msg
interactions model =
    p [ class "pt-3 grid" ]
        [ uploadImageButton model
        , backToRecipeLink model
        ]
