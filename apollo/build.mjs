import * as esbuild from "esbuild";

const { errors, warnings } = await esbuild.build({
  bundle: true,
  minify: process.env.NODE_ENV === "production",
  platform: "node",
  target: "node18",
  loader: { ".gql": "text" },
  entryPoints: ["src/index.ts"],
  outfile: "dist/index.cjs",
});

console.log({ errors, warnings });

if (errors.length) process.exit(1);
