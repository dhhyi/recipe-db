module.exports = {
  plugins: [
    require.resolve("@prettier/plugin-xml"),
    require.resolve("prettier-plugin-sh"),
    require.resolve("prettier-plugin-toml"),
  ],
  overrides: [
    { files: ["LICENSE"], options: { parser: "markdown" } },
    {
      files: ["*.svg"],
      options: {
        parser: "xml",
        xmlWhitespaceSensitivity: "ignore",
        xmlQuoteAttributes: "double",
        printWidth: 200,
      },
    },
    { files: ["*.properties"], options: { parser: "sh" } },
  ],
};
