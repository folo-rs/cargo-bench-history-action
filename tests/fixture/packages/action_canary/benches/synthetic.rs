//! CI's real Cargo bench entry point delegates engine output to the pinned faker.
//! It exercises collection without measuring wall-clock benchmark performance.

use std::env;
use std::process::{Command, ExitCode};

fn main() -> ExitCode {
    let faker = env::var_os("ACTION_CANARY_FAKER").expect("canary must provide its pinned faker");
    let status = Command::new(faker)
        // Arbitrary deterministic measurements: only storage/analysis behavior is under test.
        .args(["--criterion", "action|synthetic=100@1/99:101"])
        .status()
        .expect("pinned faker must execute");
    if status.success() {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
