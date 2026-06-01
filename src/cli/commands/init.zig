// initializes a config file with default values in `.config/docent.toml`.
// TODO: It should replace the first lines, since it copies from the repository, which uses the local schema, it should replace it with the remote one, which is the second line:
// ```
// #:schema ../schemas/docent.schema.json
// ```
// It should replace that path with `https://jassielof.github.io/docent/schemas/docent.schema.json` instead.

const default_config_file = @embedFile("../templates/docent.toml");
