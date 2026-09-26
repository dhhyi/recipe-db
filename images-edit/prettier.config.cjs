const rootConfig = require("../prettier.config.cjs");

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
