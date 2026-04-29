# `docent`

Documentation linter for Zig projects

## Usage

`docent [OPTIONS] <COMMAND> <paths>...`

## Version

`0.1.0`

## Arguments

| Name    | Required | Variadic | Description                  |
| ------- | -------- | -------- | ---------------------------- |
| `paths` | no       | yes      | Files or directories to lint |

## Options

| Flag                             | Type          | Required | Default  | Scope | Description                                                                    |
| -------------------------------- | ------------- | -------- | -------- | ----- | ------------------------------------------------------------------------------ |
| `-r, --rule <<rule>=<severity>>` | `key=value[]` | no       | `-`      | local | Override severity: <name>=<allow                                               | warn | deny | forbid> (possible values: allow, warn, deny, forbid) |
| `--all <VALUE>`                  | `enum`        | no       | `-`      | local | The level to apply to all rules. (possible values: warn, deny)                 |
| `-f, --format <VALUE>`           | `enum`        | no       | `pretty` | local | The output format of the lints. (possible values: pretty, text, minimal, json) |
| `--include-build-scripts`        | `bool`        | no       | `false`  | local | Include build.zig and build/*.zig files in lint targets.                       |
| `-h, --help`                     | `bool`        | no       | -        | local | Print help                                                                     |
| `-V, --version`                  | `bool`        | no       | -        | local | Print version                                                                  |

## Commands

- `docs`: Generate markdown documentation for the CLI
- `completion`: Generate shell completion scripts
- `help`: Print this message or help of subcommands

---

# `docent docs`

Generate markdown documentation for the CLI

## Usage

`docent docs [OPTIONS]`

## Options

| Flag                    | Type     | Required | Default       | Scope | Description                                                              |
| ----------------------- | -------- | -------- | ------------- | ----- | ------------------------------------------------------------------------ |
| `--output-dir <STRING>` | `string` | no       | `docs`        | local | Directory where markdown documentation is written.                       |
| `--mode <VALUE>`        | `enum`   | no       | `single_file` | local | Markdown layout to generate. (possible values: single_file, per_command) |
| `--file <STRING>`       | `string` | no       | `cli.md`      | local | File name to use with --mode single_file.                                |
| `-h, --help`            | `bool`   | no       | -             | local | Print help                                                               |

---

# `docent completion`

Generate shell completion scripts

## Usage

`docent completion [OPTIONS] <shell>`

## Arguments

| Name    | Required | Variadic | Description                                    |
| ------- | -------- | -------- | ---------------------------------------------- |
| `shell` | yes      | no       | One of: bash, zsh, fish, pwsh, sh, nu, nushell |

## Options

| Flag         | Type   | Required | Default | Scope | Description                                                  |
| ------------ | ------ | -------- | ------- | ----- | ------------------------------------------------------------ |
| `--dynamic`  | `bool` | no       | `false` | local | For Nushell, emit dynamic completer module (default: static) |
| `-h, --help` | `bool` | no       | -       | local | Print help                                                   |
