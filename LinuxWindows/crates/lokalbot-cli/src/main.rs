//! `lokalbot-cli`: read-only access to the LokalBot library, plus a stdio MCP server.

use clap::Parser as _;
use lokalbot_cli::{Cli, Command, run};

fn main() {
    let cli = Cli::parse();
    let is_mcp = matches!(cli.command, Command::Mcp);
    match run(cli) {
        Ok(output) => {
            if !is_mcp {
                println!("{output}");
            }
        }
        Err(err) => {
            eprintln!("Error: {}", err.message());
            std::process::exit(err.exit_code());
        }
    }
}
