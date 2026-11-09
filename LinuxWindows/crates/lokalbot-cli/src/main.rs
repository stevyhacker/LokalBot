//! `lokalbot-cli`: read-only access to the LokalBot library, a stdio MCP server,
//! and settings through the running app.

use clap::Parser as _;
use lokalbot_cli::{Cli, CliError, Command, run};

fn main() {
    let cli = Cli::parse();
    let is_mcp = matches!(cli.command, Command::Mcp);
    match run(cli) {
        Ok(output) => {
            if !is_mcp {
                println!("{output}");
            }
        }
        Err(CliError::Exit { code, stdout }) => {
            println!("{stdout}");
            std::process::exit(code);
        }
        Err(err) => {
            eprintln!("Error: {}", err.message());
            std::process::exit(err.exit_code());
        }
    }
}
