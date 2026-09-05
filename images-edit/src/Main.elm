module Main exposing (main)

import Accessibility.Role as Role
import Browser
import Browser.Navigation as Navigation
import File exposing (File)
import Html exposing (Html, a, div, figure, h1, img, input, label, p, text)
import Html.Attributes exposing (attribute, class, for, hidden, href, id, multiple, src, style, type_)
import Html.Events exposing (on)
import Json.Decode as D
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
    | Loading String



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

                GotUploadResponse upload ->
                    case upload of
                        RemoteData.Success True ->
                            Navigation.load ("/recipe/" ++ newModel.recipeId)

                        _ ->
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
    Html.main_ []
        (recipeDisplay model
            ++ uploadFeedback model
            ++ [ interactions model ]
        )


feedback : Feedback -> Html Msg
feedback f =
    case f of
        Success message ->
            p [ Role.alert, class "pt-2", style "color" "var(--pico-ins-color)" ] [ text message ]

        Failure message ->
            p [ Role.alert, class "pt-2", style "color" "var(--pico-del-color)" ] [ text message ]

        Loading message ->
            p [ class "pt-2", attribute "aria-busy" "true" ] [ text message ]


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

        RemoteData.Loading ->
            [ feedback (Loading "Lade...") ]

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


uploadFeedback : Model -> List (Html Msg)
uploadFeedback model =
    case model.uploaded of
        RemoteData.Success True ->
            [ feedback (Success "Bild hochgeladen") ]

        RemoteData.Success False ->
            [ feedback (Failure "Fehler beim Hochladen") ]

        RemoteData.Loading ->
            [ feedback (Loading "Lade hoch...") ]

        RemoteData.Failure _ ->
            [ feedback (Failure "Fehler beim Hochladen") ]

        _ ->
            []


uploadImageButton : Model -> Html Msg
uploadImageButton _ =
    let
        fileDecoder : D.Decoder File
        fileDecoder =
            D.at [ "target", "files", String.fromInt 0 ] File.decoder
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
        , label [ for "upload-image", Role.button, class "mb-0!" ] [ text "Bild hochladen" ]
        ]


backToRecipeLink : Model -> Html Msg
backToRecipeLink model =
    a [ href ("/recipe/" ++ model.recipeId), Role.button, class "secondary" ] [ text "Abbrechen" ]


interactions : Model -> Html Msg
interactions model =
    p [ class "pt-3 grid" ]
        [ uploadImageButton model
        , backToRecipeLink model
        ]
