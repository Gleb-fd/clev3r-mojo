//! Basic Plus Zed extension: wires the `bp lsp` binary (built by install.sh)
//! as the language server, in dev mode.
//!
//! Syntax highlighting / indents / outline work without the language server.

use zed_extension_api as zed;

struct BasicPlusExtension;

impl zed::Extension for BasicPlusExtension {
    fn new() -> Self {
        Self
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &zed::LanguageServerId,
        worktree: &zed::Worktree,
    ) -> zed::Result<zed::Command> {
        // Порядок поиска: tools/bp в корне открытого проекта, bp в PATH,
        // типичные места установки репозитория.
        let mut candidates: Vec<String> = vec![format!("{}/tools/bp", worktree.root_path())];
        if let Some(on_path) = worktree.which("bp") {
            candidates.push(on_path);
        }
        candidates.push("~/clev3r_mojo/tools/bp".to_string());
        candidates.push("~/Projects/clev3r_mojo/tools/bp".to_string());

        for path in &candidates {
            let expanded = match path.strip_prefix("~/") {
                Some(rest) => match std::env::var("HOME") {
                    Ok(home) => format!("{home}/{rest}"),
                    Err(_) => path.clone(),
                },
                None => path.clone(),
            };
            if std::path::Path::new(&expanded).is_file() {
                return Ok(zed::Command {
                    command: expanded,
                    args: vec!["lsp".to_string()],
                    env: Default::default(),
                });
            }
        }

        Err(
            "bp не найден: собери компилятор (./install.sh из репозитория \
             clev3r-mojo) и положи tools/bp в корень проекта или в PATH"
                .to_string(),
        )
    }
}

zed::register_extension!(BasicPlusExtension);
