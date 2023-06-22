DB := Map clone

DB clone := DB

DB clear := method(
    self empty
)

DB getAverageRating := method(id,
    ratings := self at(id)
    if (ratings == nil,
        return formatSingle(id, 0, 0),

        count := ratings size
        average := ratings values sum / count

        return formatSingle(id, average, count)
    )
)

DB getAllAverageRatings := method(
    return list()
)

DB addRating := method(id, rating, login,
    current := self at(id)
    new := if (current == nil, Map clone, current) atPut(login, rating)
    self atPut(id, new)

    return getAverageRating(id)
)
