export const typeDefs = `#graphql

type Rating {
  average: Float
  count: Int
}

type Recipe {
  id: ID!
  name: String!
  rating: Rating
}

type Query {
  test: String

  recipes: [Recipe]
  recipe(id: ID!): Recipe

  rating(id: ID!): Float
}

type Mutation {
  rate(id: ID!, rating: Int!, login: String!): Float
}

`;
