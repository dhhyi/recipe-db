const rootConfig = require("../.prettierrc.cjs");

module.exports = {
  ...rootConfig,
  overrides: [
    ...(rootConfig.overrides || []),
    {
      files: ["elm.json"],
      options: { tabWidth: 4, printWidth: 10 },
    },
  ],
};
