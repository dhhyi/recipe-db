export default {
  "*": () => ["npm run build", "npm run format"],
  "*.gql": "graphql-schema-linter",
};
