module Main exposing (main)

import Accessibility.Role as Role
import Browser
import Browser.Navigation as Navigation
import File exposing (File)
import Html exposing (Html, a, div, h2, h3, img, input, label, text)
import Html.Attributes exposing (class, for, hidden, href, id, multiple, src, style, type_)
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
    div [ class "flex flex-col gap-1" ]
        [ recipeDisplay model
        , uploadFeedback model
        , interactions model
        ]


recipeDisplay : Model -> Html Msg
recipeDisplay model =
    case model.recipe of
        RemoteData.Success maybeRecipe ->
            case maybeRecipe of
                Just recipe ->
                    div [ class "contents" ]
                        [ recipeHeading recipe
                        , recipeThumbnail recipe
                        ]

                Nothing ->
                    h3 [] [ text "Rezept nicht gefunden" ]

        RemoteData.Loading ->
            h3 [] [ text "Lade..." ]

        RemoteData.Failure _ ->
            h3 [] [ text "Fehler beim Laden" ]

        _ ->
            text ""


recipeHeading : RecipeDB.RecipeData -> Html Msg
recipeHeading recipe =
    h2 [] [ text recipe.name ]


recipeThumbnail : RecipeDB.RecipeData -> Html Msg
recipeThumbnail recipe =
    case recipe.thumbUrl of
        Just thumbUrl ->
            img [ src thumbUrl, style "max-width" "600px", style "width" "auto" ] []

        Nothing ->
            h3 [] [ text "Kein Bild vorhanden" ]


backToRecipeLink : Model -> Html Msg
backToRecipeLink model =
    a [ href ("/recipe/" ++ model.recipeId), Role.button, class "secondary" ] [ text "Abbrechen" ]


uploadFeedback : Model -> Html Msg
uploadFeedback model =
    case model.uploaded of
        RemoteData.Success True ->
            h3 [] [ text "Bild hochgeladen" ]

        RemoteData.Success False ->
            h3 [] [ text "Fehler beim Hochladen" ]

        RemoteData.Loading ->
            h3 [] [ text "Lade hoch..." ]

        RemoteData.Failure _ ->
            h3 [] [ text "Fehler beim Hochladen" ]

        _ ->
            text ""


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


interactions : Model -> Html Msg
interactions model =
    div [ class "flex flex-row gap-2 sm:gap-5 md:gap-13" ]
        [ uploadImageButton model
        , backToRecipeLink model
        ]
