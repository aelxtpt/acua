//! Acceptance probe restricted to the disposable app created by rust-client.mjs.
use cua_client::{
    Action, Client, Error, EventStreamEndReason, PasteFormat, Selection, Target, Value,
};
use serde_json::json;
use std::{
    env, fs,
    path::Path,
    thread,
    time::{Duration, Instant},
};

fn events(dir: &Path) -> Vec<Value> {
    fs::read_to_string(dir.join("events.jsonl"))
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}
fn state(dir: &Path) -> Value {
    let before = events(dir).len();
    let pending = dir.join(format!("rust-command-{}.pending", std::process::id()));
    fs::write(&pending, "state").unwrap();
    fs::rename(pending, dir.join("command")).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(state) = events(dir)
            .into_iter()
            .skip(before)
            .find(|v| v["event"] == "state")
        {
            return state;
        }
        assert!(Instant::now() < deadline, "fixture state timed out");
        thread::sleep(Duration::from_millis(10));
    }
}
fn element(text: &str, identifier: &str) -> String {
    let line = text
        .lines()
        .find(|line| line.contains(identifier))
        .expect("fixture element absent");
    line.trim_start().split_whitespace().next().unwrap().to_string()
}
fn pass(name: &str) {
    println!("PASS Rust native: {name}");
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args().collect();
    assert_eq!(
        args.len(),
        5,
        "socket, fixture directory, bundle and PID required"
    );
    // Asserts compare the bundle identifier; requests name the fixture by its
    // canonical path, because Launch Services ignores apps in temporary folders.
    let bundle = &args[3];
    let app = &args[5];
    // rust-client.mjs adds a per-run suffix so stale copies stay unambiguous.
    assert!(bundle.starts_with("test.acua.rust-fixture."), "unexpected fixture {bundle}");
    let pid: i64 = args[4].parse()?;
    let directory = Path::new(&args[2]);
    let mut cua = Client::connect_to(&args[1])?;
    pass("socket handshake");
    assert!(cua.list_apps()?.iter().any(|a| a.bundle_identifier == *app));
    pass("typed app list");
    assert_eq!(cua.event_stream_status()?["isRecording"], false);
    assert_eq!(
        cua.stop_event_stream(EventStreamEndReason::ToolStopped)?["isRecording"],
        false
    );
    pass("typed recording status and inactive stop leave capture disabled");
    // This disposable bundle is not registered with Launch Services.
    let fixture_path = directory.join("RustFixture.app");
    let policy = cua.app_policy(fixture_path.to_str().expect("fixture app path"))?;
    assert_eq!(policy["target"]["bundleIdentifier"], *app);
    assert_eq!(policy["decision"], "allowed");
    pass("app policy");
    cua.start_app(app)?;
    let appSnapshot = cua.appSnapshot(app, true)?;
    assert_eq!(appSnapshot["app"]["pid"], pid);
    assert_eq!(appSnapshot["app"]["bundleIdentifier"], *app);
    let tree = appSnapshot["appSnapshot"]["text"]
        .as_str()
        .expect("missing AX tree");
    let editor = element(tree, "input-editor");
    let button = element(tree, "input-button");
    assert!(appSnapshot["appSnapshot"]["screenshot"]["url"].as_str().is_some());
    pass("real screenshot and accessibility tree");
    let before = events(directory).len();
    let action = cua.perform_action_with_app_snapshot(app, Action::click(Target::element(button)))?;
    assert_eq!(i64::from(action.app.pid), pid);
    let after_click = action.appSnapshot;
    assert!(!after_click.text.is_empty());
    let jpeg = after_click
        .screenshot
        .expect("missing post-action screenshot");
    assert_eq!(jpeg.mime_type, "image/jpeg");
    let path = jpeg.url.strip_prefix("file://").expect("local screenshot URL");
    let mut decoded = Vec::new();
    let bytes = path.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            decoded.push(u8::from_str_radix(std::str::from_utf8(&bytes[index+1..index+3]).unwrap(), 16).unwrap());
            index += 3;
        } else { decoded.push(bytes[index]); index += 1; }
    }
    let bytes = std::fs::read(String::from_utf8(decoded).unwrap())?;
    assert!(bytes.starts_with(&[0xff, 0xd8, 0xff]));
    pass("action followed by observation returns updated accessibility text and a real JPEG file");
    assert!(events(directory)
        .iter()
        .skip(before)
        .any(|v| v["event"] == "button-action"));
    pass("button click");
    cua.perform_action(app, Action::click(Target::element(&editor)))?;
    cua.perform_action(app, Action::press_key("Super_L+a"))?;
    cua.perform_action(app, Action::type_text("Rust 🙂 café alvo fim"))?;
    cua.appSnapshot(app, true)?;
    assert_eq!(state(directory)["text"], "Rust 🙂 café alvo fim");
    pass("key chord and Unicode typing");
    cua.perform_action(
        app,
        Action::SelectText {
            element_id: editor.clone(),
            text: "alvo".into(),
            prefix: Some("café ".into()),
            suffix: Some(" fim".into()),
            selection: Selection::Text,
        },
    )?;
    assert_eq!(state(directory)["selection"][1], 4);
    pass("contextual text selection");
    cua.perform_action(
        app,
        Action::Paste {
            text: "COLADO 🙂".into(),
            format: PasteFormat::Text,
        },
    )?;
    assert_eq!(state(directory)["text"], "Rust 🙂 café COLADO 🙂 fim");
    pass("clipboard paste");
    let invalid = cua.perform_action(
        app,
        Action::SetValue {
            element_id: "99999999".into(),
            value: json!("never write"),
        },
    );
    assert!(matches!(invalid,Err(Error::Remote(ref e)) if e.code == -10008));
    assert!(!cua.is_closed());
    assert!(!cua.list_apps()?.is_empty());
    pass("native AX error and continued connection");
    assert_eq!(state(directory)["decoy"], "DO NOT TOUCH");
    pass("decoy document preserved");
    cua.stop_app(app)?;
    pass("automation session closed");
    cua.close();
    assert!(cua.is_closed());
    pass("explicit transport close");
    Ok(())
}
