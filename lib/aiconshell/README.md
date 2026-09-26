# lib/aiconshell

Pure-Ruby ports owned by parallel lanes (see `docs/architecture.md`, "Ruby ポート契約"):

- `plugins.rb` + `plugins/` — Interaction lane (issue #3)
- `ai.rb` + `ai/` — Execution lane (issue #4)
- `observability.rb` + `observability/` — EventLog lane (issue #5)

Rules:

- This directory is **explicitly required, never autoloaded**.
  `config/application.rb` lists `aiconshell` in `autoload_lib(ignore:)`, so
  Zeitwerk does not manage this namespace and `require "aiconshell/plugins"`
  (etc.) cannot double-define constants.
- Do not add `lib/aiconshell.rb` here; each lane adds its own entrypoint
  (`lib/aiconshell/<area>.rb`) that requires the files underneath it.
- Unit tests for these ports must not boot Rails or touch the network/DB.
