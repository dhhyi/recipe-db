function minimizeQuery(query) {
  return query
    .replace(/\s+/g, " ")
    .replace(/([^\w]) ([^\w])/g, "$1$2")
    .replace(/([^\w]) (\w)/g, "$1$2")
    .replace(/(\w) ([^\w])/g, "$1$2");
}

module.exports = {
  plugin(_schema, documents, _config) {
    return documents
      .map((doc) => {
        const documents = doc.document.definitions.map((def) => ({
          name: def.name.value,
          raw: def.loc.source.body.substring(def.loc.start, def.loc.end),
        }));

        return (
          `// ${doc.location}\n` +
          documents
            .map(
              ({ name, raw }) =>
                `export const ${name} = '${minimizeQuery(raw)}'`
            )
            .join("\n") +
          "\n"
        );
      })
      .join("\n");
  },
};
