mod pty;

use std::env;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        print_usage();
        return ExitCode::from(1);
    }

    match args[1].as_str() {
        "run" => {
            if args.len() < 3 {
                eprintln!("term-mesh run: missing command");
                eprintln!("Usage: term-mesh run <command> [args...]");
                return ExitCode::from(1);
            }
            let cmd = &args[2];
            let cmd_args: Vec<&str> = args[3..].iter().map(|s| s.as_str()).collect();

            match pty::run_with_pty(cmd, &cmd_args) {
                Ok(code) => ExitCode::from(code as u8),
                Err(e) => {
                    eprintln!("term-mesh run: {}", e);
                    ExitCode::from(1)
                }
            }
        }
        "help" | "--help" | "-h" => {
            print_usage();
            ExitCode::SUCCESS
        }
        other => {
            eprintln!("term-mesh: unknown command '{}'", other);
            print_usage();
            ExitCode::from(1)
        }
    }
}

fn print_usage() {
    eprintln!("term-mesh — AI agent control plane CLI");
    eprintln!();
    eprintln!("Usage:");
    eprintln!("  term-mesh run <command> [args...]   Run command in a PTY wrapper");
    eprintln!("  term-mesh help                      Show this help");
    eprintln!();
    eprintln!("Examples:");
    eprintln!("  term-mesh run claude code");
    eprintln!("  term-mesh run -- kiro-cli chat \"fix this bug\"");
}
