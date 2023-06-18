export const typeDefs = `#graphql

type Recipe {
  id: ID!
  name: String!
  rating: Float
}

type Query {
  test: String
  
  recipes: [Recipe]
  recipe(id: ID!): Recipe

  rating(id: ID!): Float
}

type Mutation {
  rate(id: ID!, rating: Int!): Float
}

`;
