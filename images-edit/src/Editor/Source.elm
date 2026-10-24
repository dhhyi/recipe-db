module Editor.Source exposing (Problem(..), decoded, dimensions, file, message)

import Crop exposing (Crop, Size)


type Problem
    = Unreadable
    | TooManyBytes
    | TooManyPixels
    | TooSmall
    | OrientationMismatch


file : String -> Int -> Result Problem ()
file mime bytes =
    if mime /= "image/jpeg" && mime /= "image/png" then
        Err Unreadable

    else if bytes > 10 * 1024 * 1024 then
        Err TooManyBytes

    else
        Ok ()


dimensions : Size -> Result Problem Crop
dimensions size =
    if size.width <= 0 || size.height <= 0 then
        Err Unreadable

    else if toFloat size.width * toFloat size.height > 40000000 then
        Err TooManyPixels

    else
        Crop.centered size |> Result.fromMaybe TooSmall


decoded : Size -> Size -> Result Problem Crop
decoded expected actual =
    if expected /= actual then
        Err OrientationMismatch

    else
        dimensions actual


message : Problem -> String
message problem =
    case problem of
        Unreadable ->
            "Das Bild konnte nicht gelesen werden. Bitte eine gültige JPEG- oder PNG-Datei auswählen."

        TooManyBytes ->
            "Die Datei ist zu groß. Erlaubt sind höchstens 10 MiB."

        TooManyPixels ->
            "Das Bild ist zu groß. Erlaubt sind höchstens 40 Millionen Pixel."

        TooSmall ->
            "Das Bild ist zu klein. Mindestens 300 × 225 Pixel im 4:3-Zuschnitt sind erforderlich."

        OrientationMismatch ->
            "Die Bildausrichtung konnte nicht zuverlässig gelesen werden. Bitte ein anderes JPEG- oder PNG-Bild auswählen."
