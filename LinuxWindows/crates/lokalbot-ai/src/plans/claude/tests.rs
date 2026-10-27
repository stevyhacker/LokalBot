use serde_json::json;

use super::*;

#[test]
fn arguments_carry_the_mac_isolation_flags() {
    let request = ChatRequest::new("sys", "Summarize.")
        .reasoning_budget(0)
        .json_schema(json!({"type": "object", "required": ["b", "a"], "properties": {"b": {"type": "string"}, "a": {"type": "array", "maxItems": 3}}}));
    let args = arguments("sonnet", ReasoningLevel::Automatic, &request, false);
    let expected_prefix: Vec<String> = [
        "-p",
        "--output-format",
        "json",
        "--no-session-persistence",
        "--safe-mode",
        "--tools",
        "",
        "--strict-mcp-config",
        "--mcp-config",
        r#"{"mcpServers":{}}"#,
        "--disable-slash-commands",
        "--setting-sources",
        "",
        "--system-prompt-file",
        "system-prompt.txt",
        "--model",
        "sonnet",
        // Notes (budget 0) run at the lowest effort on a thinking model.
        "--effort",
        "low",
        "--json-schema",
    ]
    .map(String::from)
    .to_vec();
    assert_eq!(args[..expected_prefix.len()], expected_prefix[..]);
    // Schemas pass unchanged, with stable key order.
    assert_eq!(
        args.last().unwrap(),
        r#"{"properties":{"a":{"maxItems":3,"type":"array"},"b":{"type":"string"}},"required":["b","a"],"type":"object"}"#
    );
    assert!(
        !args.iter().any(|a| a == "--bare"),
        "--bare ignores the plan sign-in"
    );

    let streaming = arguments(
        "",
        ReasoningLevel::Automatic,
        &ChatRequest::new("s", "u"),
        true,
    );
    assert_eq!(
        streaming[..5],
        [
            "-p",
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages"
        ]
        .map(String::from)
    );
    assert!(!streaming.contains(&"--model".to_string()));
    assert!(!streaming.contains(&"--effort".to_string()));
    let chosen = arguments(
        "claude-haiku-4-5",
        ReasoningLevel::High,
        &ChatRequest::new("s", "u"),
        false,
    );
    // Claude Haiku 4.5 takes no effort control.
    assert!(!chosen.contains(&"--effort".to_string()));
    let capped = arguments(
        "opus",
        ReasoningLevel::Max,
        &ChatRequest::new("s", "u").reasoning_budget(4_096),
        false,
    );
    assert_eq!(
        capped[capped.iter().position(|a| a == "--effort").unwrap() + 1],
        "medium"
    );
}

#[test]
fn content_goes_over_stdin_without_blank_blocks() {
    let mut request = ChatRequest::new("s", "Question?");
    request.context = vec!["Transcript".into(), " ".into()];
    assert_eq!(input(&request), "Transcript\n\nQuestion?");
}

#[test]
fn discovery_checks_path_then_known_install_folders() {
    let home = Path::new(if cfg!(windows) {
        "C:/Users/me"
    } else {
        "/home/me"
    });
    let local = home.join(".local/bin").join(executable_names()[0]);
    let exists = |path: &Path| path == local;
    assert_eq!(locate_in(None, Some(home), &exists), Some(local.clone()));
    let bin = if cfg!(windows) {
        "C:/tools"
    } else {
        "/opt/tools"
    };
    let on_path = Path::new(bin).join(executable_names()[0]);
    let path_var =
        std::env::join_paths([PathBuf::from("relative/dir"), PathBuf::from(bin)]).unwrap();
    let both = |path: &Path| path == local || path == on_path;
    assert_eq!(locate_in(Some(&path_var), Some(home), &both), Some(on_path));
    assert_eq!(locate_in(Some(&path_var), Some(home), &|_| false), None);
    if cfg!(windows) {
        assert_eq!(executable_names(), &["claude.exe", "claude.cmd"]);
    }
}

#[test]
fn npm_shims_resolve_to_their_script() {
    let dir = tempfile::tempdir().unwrap();
    let script = dir
        .path()
        .join("node_modules/@anthropic-ai/claude-code/cli.js");
    std::fs::create_dir_all(script.parent().unwrap()).unwrap();
    std::fs::write(&script, "").unwrap();
    let shim = dir.path().join("claude.cmd");
    std::fs::write(
        &shim,
        "@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n\
         IF EXIST \"%dp0%\\node.exe\" (\r\n  SET \"_prog=%dp0%\\node.exe\"\r\n) ELSE (\r\n  SET \"_prog=node\"\r\n)\r\n\
         endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & \"%_prog%\"  \"%dp0%\\node_modules\\@anthropic-ai\\claude-code\\cli.js\" %*\r\n",
    )
    .unwrap();
    let launch = Launch::for_executable(&shim);
    assert_eq!(launch.program, PathBuf::from("node"));
    assert_eq!(launch.prefix, vec![script.clone().into_os_string()]);
    assert_eq!(launch.folder, dir.path());
    std::fs::write(dir.path().join("node.exe"), "").unwrap();
    let bundled = Launch::for_executable(&shim);
    assert_eq!(bundled.program, dir.path().join("node.exe"));
    assert_eq!(bundled.prefix, vec![script.clone().into_os_string()]);
    // A package that ships a native binary behind the shim.
    let native_target = dir
        .path()
        .join("node_modules/@anthropic-ai/claude-code/bin/claude.exe");
    std::fs::create_dir_all(native_target.parent().unwrap()).unwrap();
    std::fs::write(&native_target, "").unwrap();
    let native_shim = dir.path().join("claude-native.cmd");
    std::fs::write(
        &native_shim,
        "@ECHO off\r\n\"%dp0%\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe\"   %*\r\n",
    )
    .unwrap();
    let launch = Launch::for_executable(&native_shim);
    assert_eq!(launch.program, native_target);
    assert!(launch.prefix.is_empty());
    // A native install runs as it is.
    let native = dir.path().join("claude");
    assert_eq!(Launch::for_executable(&native).program, native);
}

#[test]
fn auth_status_reports_the_plan_without_credentials() {
    let status = AuthStatus::parse(
        r#"{"loggedIn":true,"authMethod":"claude.ai","email":"me@example.com","subscriptionType":"max"}"#,
    )
    .unwrap();
    assert!(status.uses_subscription());
    assert_eq!(status.plan_name().as_deref(), Some("Max"));
    let key = AuthStatus::parse(r#"{"loggedIn":true,"authMethod":"api_key"}"#).unwrap();
    assert!(!key.uses_subscription());
    assert!(AuthStatus::parse("not json").is_none());
}

#[test]
fn results_map_to_text_structured_output_and_plan_errors() {
    let ok = parse_result(
        &json!({"type": "result", "result": "Hi", "usage": {"input_tokens": 2, "cache_read_input_tokens": 10, "output_tokens": 1}}),
        false,
    )
    .unwrap();
    assert_eq!(ok.text, "Hi");
    assert_eq!(ok.usage.unwrap().prompt_tokens, Some(12));
    let structured = parse_result(
        &json!({"result": "", "structured_output": {"b": 1, "a": 2}}),
        true,
    )
    .unwrap();
    assert_eq!(structured.text, r#"{"a":2,"b":1}"#);
    let err = |message: &str, status: Option<u64>| {
        parse_result(
            &json!({"is_error": true, "result": message, "api_error_status": status}),
            false,
        )
        .unwrap_err()
    };
    assert!(matches!(
        err("Not logged in · Please run /login", None).downcast_ref::<PlanError>(),
        Some(PlanError::ClaudeSignInRequired)
    ));
    assert!(matches!(
        err("Claude AI usage limit reached|1760000000", Some(429)).downcast_ref::<PlanError>(),
        Some(PlanError::ClaudeUsageLimitReached(_))
    ));
    assert!(
        err("Overloaded", Some(529))
            .downcast_ref::<AiError>()
            .unwrap()
            .is_retryable()
    );
    assert!(parse_result(&json!({"result": "x", "stop_reason": "refusal"}), false).is_err());
    let cut = parse_result(
        &json!({"result": "par", "stop_reason": "max_tokens"}),
        false,
    )
    .unwrap();
    assert!(cut.truncated);
    assert!(matches!(
        reply(
            &Output {
                stderr_tail: "Error: not logged in".into(),
                ..Output::default()
            },
            false,
            false
        )
        .unwrap_err()
        .downcast_ref::<PlanError>(),
        Some(PlanError::ClaudeSignInRequired)
    ));
}

#[test]
fn stream_lines_carry_deltas_and_the_result() {
    let delta = r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#;
    assert_eq!(parse_stream_line(delta), (Some("Hel".into()), None));
    let thinking = r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hm"}}}"#;
    assert_eq!(parse_stream_line(thinking), (None, None));
    assert!(
        parse_stream_line(r#"{"type":"result","result":"Hello"}"#)
            .1
            .is_some()
    );
    assert_eq!(parse_stream_line("garbage"), (None, None));
}

/// A stand-in `claude` that records how it was run and answers like Claude
/// Code's print mode.
#[cfg(unix)]
fn fake_claude(dir: &Path, stdout: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt as _;
    let record = dir.join("record");
    std::fs::create_dir_all(&record).unwrap();
    let answer = dir.join("answer.txt");
    std::fs::write(&answer, stdout).unwrap();
    let script = dir.join("claude");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\n\
             printf '%s\\n' \"$@\" > '{rec}/args'\n\
             cat > '{rec}/stdin'\n\
             pwd > '{rec}/cwd'\n\
             ls -A > '{rec}/listing'\n\
             cat system-prompt.txt > '{rec}/system'\n\
             stat -c '%a' system-prompt.txt > '{rec}/mode' 2>/dev/null || stat -f '%Lp' system-prompt.txt > '{rec}/mode'\n\
             printf '%s' \"${{CLAUDECODE-unset}}\" > '{rec}/claudecode'\n\
             cat '{answer}'\n",
            rec = record.display(),
            answer = answer.display(),
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    script
}

#[cfg(unix)]
#[test]
fn runs_claude_in_a_private_empty_folder_with_content_on_stdin() {
    let dir = tempfile::tempdir().unwrap();
    let executable = fake_claude(
        dir.path(),
        r#"{"type":"result","subtype":"success","is_error":false,"result":"{\"ok\":true}","structured_output":{"ok":true}}"#,
    );
    let engine = Engine {
        model: "sonnet".into(),
        level: ReasoningLevel::Automatic,
        runner: Arc::new(LiveRunner {
            executable: Some(executable),
        }),
    };
    let mut request = ChatRequest::new("System prompt here.", "Write notes.")
        .reasoning_budget(0)
        .json_schema(json!({"type": "object"}));
    request.context = vec!["Secret transcript".into()];
    // SAFETY: tests in this binary do not read CLAUDECODE concurrently.
    unsafe { std::env::set_var("CLAUDECODE", "1") };
    let completion = engine.respond(&request, None, None).unwrap();
    unsafe { std::env::remove_var("CLAUDECODE") };
    assert_eq!(completion.text, r#"{"ok":true}"#);
    let record = dir.path().join("record");
    let read = |name: &str| std::fs::read_to_string(record.join(name)).unwrap();
    let args: Vec<String> = read("args").lines().map(str::to_string).collect();
    assert_eq!(
        args,
        arguments("sonnet", ReasoningLevel::Automatic, &request, false)
    );
    // Content never appears on the command line.
    assert!(!read("args").contains("Secret transcript"));
    assert!(!read("args").contains("System prompt here."));
    assert_eq!(read("stdin"), "Secret transcript\n\nWrite notes.");
    assert_eq!(read("system"), "System prompt here.");
    assert_eq!(read("mode").trim(), "600");
    assert_eq!(read("listing").trim(), "system-prompt.txt");
    assert_eq!(read("claudecode"), "unset");
    // The folder is gone afterwards.
    assert!(!Path::new(read("cwd").trim()).exists());
}

#[cfg(unix)]
#[test]
fn streams_deltas_and_reports_cancellation() {
    let dir = tempfile::tempdir().unwrap();
    let lines = [
        r#"{"type":"system","subtype":"init"}"#,
        r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}}"#,
        r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}}"#,
        r#"{"type":"result","subtype":"success","is_error":false,"result":"Hello"}"#,
    ]
    .join("\n");
    let executable = fake_claude(dir.path(), &lines);
    let engine = Engine {
        model: String::new(),
        level: ReasoningLevel::Automatic,
        runner: Arc::new(LiveRunner {
            executable: Some(executable.clone()),
        }),
    };
    let mut deltas = Vec::new();
    let completion = engine
        .respond(
            &ChatRequest::new("", "Hi"),
            None,
            Some(&mut |d: &str| deltas.push(d.to_string())),
        )
        .unwrap();
    assert_eq!(completion.text, "Hello");
    assert_eq!(deltas, vec!["Hel", "lo"]);
    let system = std::fs::read_to_string(dir.path().join("record/system")).unwrap();
    assert_eq!(system, "You are a helpful assistant.");

    // A run that never ends stops when cancelled.
    use std::os::unix::fs::PermissionsExt as _;
    let slow = dir.path().join("slow-claude");
    std::fs::write(&slow, "#!/bin/sh\ncat > /dev/null\nsleep 30\n").unwrap();
    std::fs::set_permissions(&slow, std::fs::Permissions::from_mode(0o755)).unwrap();
    let engine = Engine {
        runner: Arc::new(LiveRunner {
            executable: Some(slow),
        }),
        ..engine
    };
    let cancel = Arc::new(AtomicBool::new(false));
    let flag = cancel.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        flag.store(true, Ordering::Relaxed);
    });
    let started = Instant::now();
    let completion = engine
        .respond(
            &ChatRequest::new("s", "u"),
            Some(&cancel),
            Some(&mut |_: &str| {}),
        )
        .unwrap();
    assert!(completion.cancelled);
    assert!(started.elapsed() < Duration::from_secs(10));
}

#[test]
fn a_missing_claude_is_reported_as_not_installed() {
    let runner = LiveRunner {
        executable: Some(PathBuf::from("/nonexistent/claude")),
    };
    let err = runner.run(&[], "", &[], None, &mut |_| {}).unwrap_err();
    assert!(matches!(
        err.downcast_ref::<PlanError>(),
        Some(PlanError::ClaudeNotInstalled)
    ));
}
