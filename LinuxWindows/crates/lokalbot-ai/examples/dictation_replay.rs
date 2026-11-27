use std::io::stdout;
use std::path::PathBuf;
use std::process::ExitCode;

use lokalbot_ai::dictation_replay::run;

fn option(args: &[String], name: &str) -> Option<String> {
    let at = args.iter().position(|a| a == name)?;
    args.get(at + 1).cloned()
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (Some(fixture), Some(server)) = (
        option(&args, "--dictation-replay"),
        option(&args, "--server-url"),
    ) else {
        eprintln!(
            "usage: dictation_replay --dictation-replay FIXTURE --server-url http://127.0.0.1:PORT/v1"
        );
        return ExitCode::FAILURE;
    };
    let token = std::env::var("LOKALBOT_REPLAY_TOKEN").unwrap_or_default();
    let model = std::env::var("LOKALBOT_REPLAY_MODEL").unwrap_or_else(|_| "local".into());
    match run(
        &PathBuf::from(fixture),
        &server,
        &token,
        &model,
        &mut stdout().lock(),
    ) {
        Ok(false) => ExitCode::SUCCESS,
        Ok(true) => ExitCode::FAILURE,
        Err(error) => {
            eprintln!("Dictation replay failed: {error}");
            ExitCode::FAILURE
        }
    }
}
