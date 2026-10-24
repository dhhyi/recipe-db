module Main exposing (main)

import Browser
import Editor.Bridge
import Editor.State
import Editor.Types exposing (Model, Msg(..))
import Editor.View
import RecipeDB


main : Program { recipeId : String } Model Msg
main =
    Browser.element
        { init =
            \flags ->
                ( Editor.Types.init flags.recipeId
                , RecipeDB.makeRecipeRequest flags.recipeId GotRecipe
                )
        , update = Editor.State.update
        , view = Editor.View.view
        , subscriptions = \_ -> Editor.Bridge.events Bridge
        }
