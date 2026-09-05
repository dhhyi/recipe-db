fn main() {
    // graphql_client's derive macro reads these at compile time, but cargo can't
    // detect that dependency on its own, so trigger a rebuild on changes.
    println!("cargo:rerun-if-changed=recipe-db.graphqls");
    println!("cargo:rerun-if-changed=operations.graphql");
}
