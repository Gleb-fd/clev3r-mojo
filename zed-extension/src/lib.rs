//! Basic Plus Zed extension: wires the local `tools/bp lsp` binary
//! as the language server for dev mode.
//!
//! NOTE: `tools/bp lsp` is currently a stub (prints "not implemented"),
//! so the server will fail to start until the LSP is implemented.
//! Syntax highlighting / indents / outline work without it.

use zed_extension_api as zed;

/// Dev-mode path to the locally built Basic Plus CLI.
/// Built via: `uv run mojo build src/bp/main.mojo -o tools/bp`
/// (see tasks.json, task "bp: build tools/bp").
const DEV_LSP_PATH: &str = "/home/ssssq/Projects/clev3r_mojo/tools/bp";

struct BasicPlusExtension;

impl zed::Extension for BasicPlusExtension {
    fn new() -> Self {
        Self
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &zed::LanguageServerId,
        _worktree: &zed::Worktree,
    ) -> zed::Result<zed::Command> {
        Ok(zed::Command {
            command: DEV_LSP_PATH.to_string(),
            args: vec!["lsp".to_string()],
            env: Default::default(),
        })
    }
}

zed::register_extension!(BasicPlusExtension);
