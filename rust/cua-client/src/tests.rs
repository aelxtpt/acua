use super::*;
use std::{os::unix::ffi::OsStrExt, thread};

#[cfg(target_os = "macos")]
mod long_socket;
#[cfg(target_os = "macos")]
mod service_endpoint;

#[test]
fn socket_override_trims_text_without_changing_unix_path_bytes() {
    assert_eq!(
        socket_override(OsStr::new(" \t\n/tmp/owned cua.sock\r ")),
        Some(OsStr::new("/tmp/owned cua.sock"))
    );
    assert_eq!(socket_override(OsStr::new("\u{00a0}\t\n ")), None);
    assert_eq!(socket_override(OsStr::new("\u{200b}")), None);
    assert_eq!(socket_override(OsStr::new("")), None);
    let raw = OsStr::from_bytes(b"/tmp/socket-\xff ");
    assert_eq!(socket_override(raw), Some(raw));
}

fn read_frame(stream: &mut UnixStream) -> Value {
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let mut header = [0; 4];
    stream.read_exact(&mut header).unwrap();
    let len = u32::from_le_bytes(header) as usize;
    assert!(len <= MAX_FRAME_BYTES);
    let mut body = vec![0; len];
    stream.read_exact(&mut body).unwrap();
    serde_json::from_slice(&body).unwrap()
}
fn send(stream: &mut UnixStream, value: Value) {
    let body = serde_json::to_vec(&value).unwrap();
    stream
        .write_all(&(body.len() as u32).to_le_bytes())
        .unwrap();
    stream.write_all(&body).unwrap();
}

fn send_literal(stream: &mut UnixStream, body: &str) {
    stream.write_all(&(body.len() as u32).to_le_bytes()).unwrap();
    stream.write_all(body.as_bytes()).unwrap();
}

#[test]
fn native_models_preserve_first_duplicate_keys_including_escaped_and_nested_keys() {
    let state: AppState = serde_json::from_str(
        r#"{"\u0061ctive":false,"active":true,"currentApp":{"pid":12,"pid":"invalid","bundleIdentifier":"owned","bundleIdentifier":null}}"#,
    ).unwrap();
    assert!(!state.active);
    assert_eq!(state.current_app.unwrap().pid, 12);
    assert!(serde_json::from_str::<AppState>(r#"{"active":null,"active":true}"#).is_err());
    // Later values must still be valid JSON, even when a key already exists.
    assert!(serde_json::from_str::<AppState>(r#"{"active":true,"active":{]}"#).is_err());
    assert!(matches!(serde_json::from_str::<CaptureStartResponse>(
        r#"{"result":"started","result":"unknown"}"#).unwrap(), CaptureStartResponse::Started { .. }));
}

#[test]
fn response_duplicate_keys_preserve_native_values_without_losing_frame_alignment() {
    let (mut client, task) = peer(|stream| {
        assert_eq!(read_frame(stream)["id"], 2);
        send_literal(stream, r#"{"jsonrpc":"2.0","jsonrpc":"wrong","id":2,"id":999,"result":{"active":false,"active":"invalid"},"result":null}"#);
        assert_eq!(read_frame(stream)["id"], 3);
        send(stream, json!({"jsonrpc":"2.0","id":3,"result":true}));
    });
    assert!(!client.request::<AppState>("Owned", json!({})).unwrap().active);
    assert!(client.request::<bool>("Recovery", json!({})).unwrap());
    task.join().unwrap();
}

#[test]
fn invalid_first_typed_value_is_not_replaced_and_valid_frame_remains_usable() {
    let (mut client, task) = peer(|stream| {
        read_frame(stream);
        send_literal(stream, r#"{"jsonrpc":"2.0","id":2,"result":{"active":"invalid","active":true}}"#);
        assert_eq!(read_frame(stream)["id"], 3);
        send(stream, json!({"jsonrpc":"2.0","id":3,"result":true}));
    });
    assert!(matches!(client.request::<AppState>("Owned", json!({})), Err(Error::Json(_))));
    assert!(!client.is_closed());
    assert!(client.request::<bool>("Recovery", json!({})).unwrap());
    task.join().unwrap();
}

#[test]
fn malformed_later_duplicate_and_positional_remote_error_close_the_connection() {
    for response in [
        r#"{"jsonrpc":"2.0","id":2,"result":true,"result":{]}"#,
        r#"{"jsonrpc":"2.0","id":2,"error":[-32602,"invalid",null]}"#,
    ] {
        let (mut client, task) = peer(move |stream| {
            read_frame(stream);
            send_literal(stream, response);
        });
        assert!(client.request::<Value>("Owned", json!({})).is_err());
        assert!(client.is_closed());
        task.join().unwrap();
    }
}
fn handshake(stream: &mut UnixStream) {
    assert_eq!(
        read_frame(stream),
        json!({"id":1,"jsonrpc":"2.0","method":"ping","params":{"clientApiVersion":API_VERSION}})
    );
    send(
        stream,
        json!({"id":1,"jsonrpc":"2.0","result":{"serverApiVersion":API_VERSION}}),
    );
}
fn peer(body: impl FnOnce(&mut UnixStream) + Send + 'static) -> (Client, thread::JoinHandle<()>) {
    let (client, mut server) = UnixStream::pair().unwrap();
    let task = thread::spawn(move || {
        handshake(&mut server);
        body(&mut server);
    });
    let client = Client::from_stream(client, ClientOptions::default()).unwrap();
    (client, task)
}

#[test]
fn envelope_metadata_deadline_unicode_and_sequential_ids() {
    let (mut client, task) = peer(|stream| {
        for id in [2, 3] {
            let frame = read_frame(stream);
            assert_eq!(frame["id"], id);
            assert_eq!(frame["method"], "request");
            assert_eq!(frame["params"]["clientApiVersion"], API_VERSION);
            assert_eq!(frame["params"]["requestType"], "CustomRequest");
            assert_eq!(frame["params"]["request"]["text"], "Olá 🙂 é");
            assert_eq!(
                frame["params"]["agentTurnMetadata"],
                json!({"thread":"owned-test"})
            );
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_millis() as i64;
            let deadline = frame["params"]["deadlineUnixMilliseconds"]
                .as_i64()
                .unwrap();
            assert!((now..=now + 3000).contains(&deadline));
            send(
                stream,
                json!({"id":id,"jsonrpc":"2.0","result":{"ok":true}}),
            );
        }
    });
    let options = RequestOptions {
        timeout: Some(Duration::from_secs(2)),
        agent_metadata: Some(json!({"thread":"owned-test"})),
    };
    for _ in 0..2 {
        let value: Value = client
            .request_with_options("CustomRequest", json!({"text":"Olá 🙂 é"}), &options)
            .unwrap();
        assert_eq!(value, json!({"ok":true}));
    }
    task.join().unwrap();
}

#[test]
fn fragmented_utf8_and_header_are_reassembled() {
    let (mut client, task) = peer(|stream| {
        let req = read_frame(stream);
        let body = serde_json::to_vec(&json!({"id":req["id"],"jsonrpc":"2.0","result":"🙂 café"}))
            .unwrap();
        let frame: Vec<u8> = (body.len() as u32)
            .to_le_bytes()
            .into_iter()
            .chain(body)
            .collect();
        for byte in frame {
            stream.write_all(&[byte]).unwrap();
        }
    });
    let value: String = client.request("Fragmented", json!({})).unwrap();
    assert_eq!(value, "🙂 café");
    task.join().unwrap();
}

#[test]
fn valid_remote_error_preserves_code_data_and_connection() {
    let (mut client, task) = peer(|stream| {
        let req = read_frame(stream);
        send(
            stream,
            json!({"id":req["id"],"jsonrpc":"2.0","error":{"code":-123456,"message":"native failure","data":{"reason":9}}}),
        );
        let req = read_frame(stream);
        send(
            stream,
            json!({"id":req["id"],"jsonrpc":"2.0","result":null}),
        );
    });
    assert!(matches!(
        client.request::<Value>("Fail", json!({})),
        Err(Error::Remote(RemoteError {
            code: -123456,
            data: Some(_),
            ..
        }))
    ));
    assert!(!client.is_closed());
    client.request::<()>("Next", json!({})).unwrap();
    task.join().unwrap();
}

#[test]
fn malformed_responses_close_and_do_not_retry_actions() {
    let responses = [
        json!({"id":99,"jsonrpc":"2.0","result":null}),
        json!({"id":2,"jsonrpc":"1.0","result":null}),
        json!({"id":2,"jsonrpc":"2.0","result":null,"error":{"code":1,"message":"x"}}),
        json!({"id":2,"jsonrpc":"2.0"}),
        json!({"id":2,"jsonrpc":"2.0","error":{"code":"bad","message":"x"}}),
        json!({"id":2,"jsonrpc":"2.0","error":null}),
        json!({"id":2.0,"jsonrpc":"2.0","result":null}),
    ];
    for response in responses {
        let (mut client, task) = peer(move |stream| {
            let _ = read_frame(stream);
            send(stream, response);
            let mut byte = [0];
            assert_eq!(stream.read(&mut byte).unwrap(), 0);
        });
        assert!(matches!(
            client.perform_action("owned-fixture", Action::type_text("once")),
            Err(Error::Protocol(_))
        ));
        assert!(client.is_closed());
        assert!(matches!(
            client.request::<Value>("Next", json!({})),
            Err(Error::Closed)
        ));
        task.join().unwrap();
    }
}

#[test]
fn oversized_invalid_utf8_invalid_json_empty_and_truncated_frames_close() {
    let frames = [
        (MAX_FRAME_BYTES as u32 + 1).to_le_bytes().to_vec(),
        vec![1, 0, 0, 0, 0xff],
        vec![1, 0, 0, 0, b'{'],
        vec![0, 0, 0, 0],
        vec![10, 0, 0, 0, b'{'],
        vec![1, 0],
    ];
    for frame in frames {
        let (mut client, task) = peer(move |stream| {
            read_frame(stream);
            stream.write_all(&frame).unwrap();
        });
        assert!(client.request::<Value>("BadFrame", json!({})).is_err());
        assert!(client.is_closed());
        task.join().unwrap();
    }
}

#[test]
fn whole_rpc_deadline_closes_without_retry() {
    let (mut client, task) = peer(|stream| {
        read_frame(stream);
        // Incomplete header: the deadline must cover the entire response.
        stream.write_all(&[20]).unwrap();
        thread::sleep(Duration::from_millis(200));
        let mut byte = [0];
        assert_eq!(stream.read(&mut byte).unwrap(), 0);
    });
    let start = Instant::now();
    let options = RequestOptions {
        timeout: Some(Duration::from_millis(40)),
        ..Default::default()
    };
    assert!(matches!(
        client.request_with_options::<Value>("Slow", json!({}), &options),
        Err(Error::Io(_))
    ));
    assert!(start.elapsed() < Duration::from_secs(1));
    assert!(client.is_closed());
    task.join().unwrap();
}

#[test]
fn write_backpressure_obeys_the_same_rpc_deadline() {
    let (client_socket, mut server) = UnixStream::pair().unwrap();
    let task = thread::spawn(move || {
        handshake(&mut server);
        // Do not consume the request: a large payload must fill the send buffer.
        thread::sleep(Duration::from_millis(200));
    });
    let mut client = Client::from_stream(client_socket, ClientOptions::default()).unwrap();
    let options = RequestOptions {
        timeout: Some(Duration::from_millis(40)),
        ..Default::default()
    };
    let start = Instant::now();
    assert!(matches!(
        client.request_with_options::<Value>("Backpressure", "x".repeat(4_000_000), &options),
        Err(Error::Io(_))
    ));
    assert!(start.elapsed() < Duration::from_secs(2));
    assert!(client.is_closed());
    task.join().unwrap();
}

#[test]
fn request_id_exhaustion_and_explicit_close_do_not_send() {
    let (mut client, task) = peer(|stream| {
        let mut byte = [0];
        assert_eq!(stream.read(&mut byte).unwrap(), 0);
    });
    client.next_id = i64::MAX as u64 + 1;
    assert!(matches!(
        client.request::<Value>("NoID", json!({})),
        Err(Error::InvalidInput(_))
    ));
    assert!(!client.is_closed());
    client.close();
    client.close();
    assert!(matches!(
        client.request::<Value>("Closed", json!({})),
        Err(Error::Closed)
    ));
    task.join().unwrap();
}

#[test]
fn handshake_rejects_wrong_or_missing_version_and_remote_auth_error() {
    for response in [
        json!({"id":1,"jsonrpc":"2.0","result":{"serverApiVersion":"old"}}),
        json!({"id":1,"jsonrpc":"2.0","result":{}}),
        json!({"id":1,"jsonrpc":"2.0","error":{"code":-10000,"message":"unauthorized"}}),
    ] {
        let (client, mut server) = UnixStream::pair().unwrap();
        let task = thread::spawn(move || {
            read_frame(&mut server);
            send(&mut server, response);
        });
        assert!(Client::from_stream(client, ClientOptions::default()).is_err());
        task.join().unwrap();
    }
}

#[test]
fn local_errors_do_not_write_or_break_connection() {
    let (mut client, task) = peer(|stream| {
        let req = read_frame(stream);
        assert_eq!(req["id"], 2);
        assert_eq!(req["params"]["requestType"], "Valid");
        send(stream, json!({"id":2,"jsonrpc":"2.0","result":null}));
    });
    assert!(client.request::<Value>(" ", json!({})).is_err());
    assert!(client.perform_action(" ", Action::type_text("x")).is_err());
    for pages in [f64::NAN, f64::INFINITY, -1.0, 0.0] {
        assert!(client
            .perform_action(
                "fixture",
                Action::Scroll {
                    at: Target::element(0),
                    direction: Direction::Down,
                    pages
                }
            )
            .is_err());
    }
    assert!(client
        .perform_action(
            "fixture",
            Action::PressKey {
                key: "x".into(),
                duration: Some(f64::NAN)
            }
        )
        .is_err());
    assert!(client
        .perform_action("fixture", Action::press_key(" "))
        .is_err());
    assert!(Point::new(f64::NAN, 0.0).is_err());
    assert!(Point::new(0.0, f64::NEG_INFINITY).is_err());
    assert!(client
        .request::<Value>("Large", "x".repeat(MAX_FRAME_BYTES))
        .is_err());
    for timeout in [Duration::ZERO, Duration::from_secs(86401)] {
        assert!(client
            .request_with_options::<Value>(
                "No",
                json!({}),
                &RequestOptions {
                    timeout: Some(timeout),
                    ..Default::default()
                }
            )
            .is_err());
    }
    assert!(!client.is_closed());
    client.request::<()>("Valid", json!({})).unwrap();
    task.join().unwrap();
}

#[test]
fn typed_result_mismatch_does_not_break_connection_and_app_path_is_optional() {
    let (mut client, task) = peer(|stream| {
        for id in [2, 3] {
            read_frame(stream);
            send(
                stream,
                json!({"id":id,"jsonrpc":"2.0","result":[
                    {"bundleIdentifier":"fixture","displayName":"Fixture","isRunning":true,"future":7},
                    {"bundleIdentifier":"recent","displayName":"Recent","isRunning":false,
                     "isFrontmost":false,"lastUsedDate":724_123_456.25,"useCount":9}
                ]}),
            );
        }
    });
    assert!(matches!(
        client.request::<String>("WrongType", json!({})),
        Err(Error::Json(_))
    ));
    assert!(!client.is_closed());
    let apps = client.list_apps().unwrap();
    assert!(apps[0].app_path.is_none());
    assert_eq!(apps[0].extra["future"], 7);
    assert_eq!(apps[0].is_frontmost(), None);
    assert_eq!(apps[1].is_frontmost(), Some(false));
    assert_eq!(apps[1].last_used_date(), Some(724_123_456.25));
    assert_eq!(apps[1].use_count(), Some(9));
    task.join().unwrap();
}

#[test]
fn exact_swift_action_shapes() {
    let actions = [
        (
            Action::click(Target::coordinate(10.0, 20.0).unwrap()),
            json!({"click":{"at":{"coordinate":{"_0":[10.0,20.0]}},"clickCount":1,"mouseButton":0}}),
        ),
        (
            Action::Click {
                at: Target::element(7),
                click_count: 2,
                mouse_button: MouseButton::Right,
                key: Some("Shift_L".into()),
                duration: Some(0.2),
            },
            json!({"click":{"at":{"elementID":{"_0":"7"}},"clickCount":2,"mouseButton":1,"key":"Shift_L","duration":0.2}}),
        ),
        (
            Action::Drag {
                from: Point::new(-2.0, 3.0).unwrap(),
                to: Point::new(10.0, 25.0).unwrap(),
            },
            json!({"drag":{"from":[-2.0,3.0],"to":[10.0,25.0]}}),
        ),
        (Action::type_text("Olá 🙂"), json!({"type":{"_0":"Olá 🙂"}})),
        (
            Action::press_key("Control_L+a"),
            json!({"pressKey":{"_0":"Control_L+a"}}),
        ),
        (
            Action::Paste {
                text: "**x**".into(),
                format: PasteFormat::Markdown,
            },
            json!({"paste":{"text":"**x**","format":"md"}}),
        ),
        (
            Action::Scroll {
                at: Target::element(2),
                direction: Direction::Down,
                pages: 1.5,
            },
            json!({"scroll":{"at":{"elementID":{"_0":"2"}},"direction":"down","pages":1.5}}),
        ),
        (
            Action::SetValue {
                element_id: "4".into(),
                value: json!("owned"),
            },
            json!({"setValue":{"elementID":"4","value":"owned"}}),
        ),
        (
            Action::SelectText {
                element_id: "3".into(),
                text: "x".into(),
                prefix: Some("a".into()),
                suffix: None,
                selection: Selection::CursorAfter,
            },
            json!({"selectText":{"elementID":"3","text":"x","prefix":"a","selection":"cursor_after"}}),
        ),
        (
            Action::PerformSecondaryAction {
                action: "Show Menu".into(),
                element_id: "8".into(),
            },
            json!({"performSecondaryAction":{"action":"Show Menu","elementID":"8"}}),
        ),
    ];
    for (action, expected) in actions {
        action.validate().unwrap();
        assert_eq!(serde_json::to_value(action).unwrap(), expected);
    }
    assert_eq!(serde_json::to_value(MouseButton::Middle).unwrap(), 2);
}

#[test]
fn native_click_integer_ranges_are_preserved() {
    let action = Action::Click {
        at: Target::element(7),
        click_count: i64::MAX as u64,
        mouse_button: MouseButton::Other(u32::MAX),
        key: None,
        duration: None,
    };
    action.validate().unwrap();
    let wire = serde_json::to_value(action).unwrap();
    assert_eq!(wire["click"]["mouseButton"], u32::MAX);
    assert_eq!(wire["click"]["clickCount"], i64::MAX);
    let invalid = Action::Click {
        at: Target::element(7),
        click_count: u64::MAX,
        mouse_button: MouseButton::Left,
        key: None,
        duration: None,
    };
    assert!(matches!(invalid.validate(), Err(Error::InvalidInput(_))));
}

#[test]
fn typed_capture_stream_preserves_native_shapes() {
    let (mut client, task) = peer(|stream| {
        let send_result = |stream: &mut UnixStream, kind: &str, request: Value, result: Value| {
            let frame = read_frame(stream);
            assert_eq!(frame["params"]["requestType"], kind);
            assert_eq!(frame["params"]["request"], request);
            send(
                stream,
                json!({"id": frame["id"], "jsonrpc": "2.0", "result": result}),
            );
        };
        send_result(
            stream,
            capture::START_REQUEST,
            json!({
                "app": "fixture", "requestId": "capture", "permissionRequestId": "permission", "version": 2,
                "animationTarget": {
                    "destinationFrame": {"x": -10.0, "y": 20.0, "width": 30.0, "height": 40.0},
                    "destinationCornerRadius": 8.0,
                    "destinationBackgroundColor": {"red": 1, "green": 2, "blue": 3},
                    "presentationStyle": "quick_chat",
                    "agentDisplay": {"id": 1, "bounds": {"x": -10.0, "y": 20.0, "width": 30.0, "height": 40.0},
                        "workArea": {"x": -10.0, "y": 20.0, "width": 30.0, "height": 40.0}, "scaleFactor": 2.0}
                }
            }),
            json!({"result": "started", "animationDuration": 1.25, "transitionSnapshotHeight": 40.0,
                   "transitionSpringResponse": 0.5, "transitionSpringDampingFraction": 0.8}),
        );

        let app = json!({"pid": 99, "bundleIdentifier": "com.example.fixture"});
        let snapshot = "file:///tmp/frame%20name.png";
        for result in [
            json!({"type": "metadata", "app": app}),
            json!({"type": "axText", "app": app, "text": "0 window"}),
            json!({"type": "screenshot", "app": app, "screenshot": {"url": "file:///tmp/image.jpg", "mimeType": "image/jpeg"}}),
            json!({"type": "screenshot", "app": app, "transitionSnapshotURL": snapshot}),
            json!({"type": "completed", "app": app, "transitionSnapshotURL": snapshot}),
        ] {
            send_result(
                stream,
                capture::NEXT_REQUEST,
                json!({"requestId": "capture"}),
                result,
            );
        }
        send_result(
            stream,
            capture::START_REQUEST,
            json!({"app": "fixture", "requestId": "denied"}),
            json!({"result": "appshot_permissions_abandoned", "permissionGrantState": "screen_recording_granted"}),
        );
        send_result(
            stream,
            capture::START_REQUEST,
            json!({"app": "fixture", "requestId": "failed", "version": 42}),
            json!({"result": "started"}),
        );
        send_result(
            stream,
            capture::NEXT_REQUEST,
            json!({"requestId": "failed"}),
            json!({"type": "failed", "app": app, "failureReason": "screenshot_capture_failed"}),
        );
    });

    let frame = CaptureRect {
        x: -10.0,
        y: 20.0,
        width: 30.0,
        height: 40.0,
    };
    let mut options = CaptureOptions {
        version: Some(CaptureVersion::RELIABLE_FINAL_FRAME),
        permission_request_id: Some("permission".into()),
        animation_target: Some(CaptureAnimationTarget {
            destination_frame: frame,
            destination_corner_radius: Some(f64::NAN),
            destination_background_color: Some(CaptureColor {
                red: 1,
                green: 2,
                blue: 3,
            }),
            destination_primary_text_color: None,
            presentation_style: CapturePresentationStyle::QuickChat,
            agent_display: CaptureDisplay {
                id: 1,
                bounds: frame,
                work_area: frame,
                scale_factor: 2.0,
            },
        }),
    };
    assert!(matches!(
        client.start_capture_typed("fixture", "invalid", &options),
        Err(Error::InvalidInput(_))
    ));
    options
        .animation_target
        .as_mut()
        .unwrap()
        .destination_corner_radius = Some(8.0);
    assert_eq!(
        client
            .start_capture_typed("fixture", "capture", &options)
            .unwrap(),
        CaptureStartResponse::Started {
            animation_duration: Some(1.25),
            transition_snapshot_height: Some(40.0),
            transition_spring_response: Some(0.5),
            transition_spring_damping_fraction: Some(0.8),
            permission_grant_state: None,
        }
    );
    let metadata = client.next_capture_update_typed("capture").unwrap();
    assert_eq!(metadata.kind, CaptureUpdateKind::Metadata);
    assert_eq!(metadata.app.pid, 99);
    assert!(metadata.app.app_path.is_none() && !metadata.is_terminal());
    let text = client.next_capture_update_typed("capture").unwrap();
    assert_eq!(text.kind, CaptureUpdateKind::AxText);
    assert_eq!(text.text.as_deref(), Some("0 window"));
    let image = client.next_capture_update_typed("capture").unwrap();
    assert_eq!(image.kind, CaptureUpdateKind::Screenshot);
    assert_eq!(image.screenshot.unwrap().mime_type, "image/jpeg");
    let transition = client.next_capture_update_typed("capture").unwrap();
    assert_eq!(transition.kind, CaptureUpdateKind::Screenshot);
    assert!(transition.screenshot.is_none());
    assert_eq!(
        transition.transition_snapshot_url.as_deref(),
        Some("file:///tmp/frame%20name.png")
    );
    let complete = client.next_capture_update_typed("capture").unwrap();
    assert_eq!(complete.kind, CaptureUpdateKind::Completed);
    assert!(complete.is_terminal());
    assert_eq!(
        complete.transition_snapshot_url,
        transition.transition_snapshot_url
    );
    assert_eq!(
        client
            .start_capture_typed("fixture", "denied", &CaptureOptions::default())
            .unwrap(),
        CaptureStartResponse::PermissionsAbandoned {
            permission_grant_state: Some(CapturePermissionState::ScreenRecordingGranted),
            animation_duration: None,
            transition_snapshot_height: None,
            transition_spring_response: None,
            transition_spring_damping_fraction: None,
        }
    );
    let future = CaptureOptions {
        version: Some(CaptureVersion(42)),
        ..CaptureOptions::default()
    };
    assert!(matches!(
        client
            .start_capture_typed("fixture", "failed", &future)
            .unwrap(),
        CaptureStartResponse::Started {
            animation_duration: None,
            ..
        }
    ));
    let failure = client.next_capture_update_typed("failed").unwrap();
    assert_eq!(failure.kind, CaptureUpdateKind::Failed);
    assert!(failure.is_terminal());
    assert_eq!(
        failure.failure_reason,
        Some(CaptureFailureReason::ScreenshotCaptureFailed)
    );
    task.join().unwrap();
}

#[test]
fn typed_frontmost_window_preserves_optional_title_and_empty_response() {
    let (mut client, task) = peer(|stream| {
        for result in [
            json!({"bundleIdentifier":"example.editor","name":"Editor","windowTitle":"Olá"}),
            json!({"bundleIdentifier":"example.editor","name":"Editor"}),
            Value::Null,
        ] {
            let frame = read_frame(stream);
            assert_eq!(
                frame["params"]["requestType"],
                "ComputerUseIPCFrontmostWindowRequest"
            );
            assert_eq!(frame["params"]["request"], json!({}));
            send(
                stream,
                json!({"id":frame["id"],"jsonrpc":"2.0","result":result}),
            );
        }
    });
    let window = client.frontmost_window_typed().unwrap().unwrap();
    assert_eq!(window.bundle_identifier, "example.editor");
    assert_eq!(window.name, "Editor");
    assert_eq!(window.window_title.as_deref(), Some("Olá"));
    let untitled = client.frontmost_window_typed().unwrap().unwrap();
    assert_eq!(untitled.window_title, None);
    assert_eq!(client.frontmost_window_typed().unwrap(), None);
    task.join().unwrap();
}

#[test]
fn typed_audio_preserves_default_duration_and_wav_url() {
    let wav = "file:///tmp/%C3%A1udio%20do%20agente.wav";
    let (mut client, task) = peer(move |stream| {
        for (kind, request, result) in [
            ("StartAudioRecording", json!({}), json!({})),
            ("StopAudioRecording", json!({}), json!({"url":wav})),
            (
                "StartAudioRecording",
                json!({"maxDurationMilliseconds":100}),
                json!({}),
            ),
            ("StopAudioRecording", json!({}), json!({"url":false})),
            (
                "StartAudioRecording",
                json!({"maxDurationMilliseconds":300_000}),
                json!({}),
            ),
        ] {
            let frame = read_frame(stream);
            assert_eq!(
                frame["params"]["requestType"],
                format!("ComputerUseIPC{kind}Request")
            );
            assert_eq!(frame["params"]["request"], request);
            send(
                stream,
                json!({"id":frame["id"],"jsonrpc":"2.0","result":result}),
            );
        }
    });
    for invalid in [0, 99, 300_001, u64::MAX] {
        assert!(matches!(
            client.start_audio_recording_typed(AudioRecordingOptions {
                max_duration_milliseconds: Some(invalid),
            }),
            Err(Error::InvalidInput(_))
        ));
    }
    client
        .start_audio_recording_typed(AudioRecordingOptions::default())
        .unwrap();
    assert_eq!(client.stop_audio_recording_typed().unwrap().url, wav);
    client
        .start_audio_recording_typed(AudioRecordingOptions {
            max_duration_milliseconds: Some(100),
        })
        .unwrap();
    assert!(matches!(
        client.stop_audio_recording_typed(),
        Err(Error::Json(_))
    ));
    client
        .start_audio_recording_typed(AudioRecordingOptions {
            max_duration_milliseconds: Some(300_000),
        })
        .unwrap();
    task.join().unwrap();
}

#[test]
fn all_core_routes_and_capture_options() {
    let (mut client, task) = peer(|stream| {
        let expected = [
            ("AppPolicy", json!({"app":"fixture"})),
            ("AppStart", json!({"app":"fixture"})),
            ("AppStop", json!({"app":"fixture"})),
            (
                "AppModify",
                json!({"app":"fixture","modification":{"activate":{}}}),
            ),
            (
                "AppModify",
                json!({"app":"fixture","modification":{"deactivate":{}}}),
            ),
            ("FrontmostWindow", json!({})),
            ("AppGetAppSnapshot", json!({"app":"fixture","disableDiff":true})),
            (
                "AppStartCapture",
                json!({"app":"fixture","requestId":"owned","permissionRequestId":"legacy-permission","version":2}),
            ),
            ("AppNextCaptureUpdate", json!({"requestId":"owned"})),
            (
                "AppPerformAction",
                json!({"app":"fixture","action":{"type":{"_0":"x"}}}),
            ),
            (
                "StartAudioRecording",
                json!({"maxDurationMilliseconds":500}),
            ),
            ("StopAudioRecording", json!({})),
            (
                "TurnEnded",
                json!({"threadID":"owned","turnID":"finished"}),
            ),
            ("TurnEnded", json!({"threadID":"owned"})),
            ("EventStreamStart", json!({})),
            ("EventStreamStatus", json!({})),
            ("EventStreamStop", json!({"reason":"tool_stopped"})),
        ];
        for (kind, request) in expected {
            let frame = read_frame(stream);
            assert_eq!(
                frame["params"]["requestType"],
                format!("ComputerUseIPC{kind}Request")
            );
            assert_eq!(frame["params"]["request"], request);
            assert!(frame["params"].get("agentTurnMetadata").is_none());
            let result = if kind == "TurnEnded" {
                json!({})
            } else {
                Value::Null
            };
            send(
                stream,
                json!({"id":frame["id"],"jsonrpc":"2.0","result":result}),
            );
        }
    });
    client.app_policy("fixture").unwrap();
    client.start_app("fixture").unwrap();
    client.stop_app("fixture").unwrap();
    client
        .modify_app("fixture", AppModification::Activate)
        .unwrap();
    client
        .modify_app("fixture", AppModification::Deactivate)
        .unwrap();
    assert!(client.frontmost_window().unwrap().is_none());
    client.appSnapshot("fixture", true).unwrap();
    client
        .start_capture(
            "fixture",
            "owned",
            json!({"app":"ignored","requestId":"ignored","requestID":"legacy","permissionRequestID":"legacy-permission","version":2}),
        )
        .unwrap();
    client.next_capture_update("owned").unwrap();
    client
        .perform_action("fixture", Action::type_text("x"))
        .unwrap();
    client.start_audio_recording(500).unwrap();
    client.stop_audio_recording().unwrap();
    client.agent_turn_ended("owned", Some("finished")).unwrap();
    client.agent_turn_ended("owned", None).unwrap();
    client.start_event_stream().unwrap();
    client.event_stream_status().unwrap();
    client
        .stop_event_stream(EventStreamEndReason::ToolStopped)
        .unwrap();
    task.join().unwrap();
}

#[test]
fn native_turn_metadata_and_recording_reason_spellings() {
    let value: Value = TurnMetadata {
        session_id: Some(String::new()),
        turn_started_at_unix_ms: Some(0),
        user_input_requested_during_turn: Some(false),
        ..Default::default()
    }
    .into();
    assert_eq!(
        value,
        json!({"session_id":"","turn_started_at_unix_ms":0,"user_input_requested_during_turn":false})
    );
    let empty: Value = TurnMetadata::default().into();
    assert_eq!(empty, json!({}));
    for (reason, expected) in [
        (EventStreamEndReason::ToolStopped, "tool_stopped"),
        (EventStreamEndReason::DebugUiStopped, "debug_ui_stopped"),
        (
            EventStreamEndReason::RecordingControlsStopped,
            "recording_controls_stopped",
        ),
        (
            EventStreamEndReason::RecordingControlsCancelled,
            "recording_controls_cancelled",
        ),
        (EventStreamEndReason::MaxDuration, "max_duration"),
        (
            EventStreamEndReason::ServiceTerminated,
            "service_terminated",
        ),
    ] {
        assert_eq!(serde_json::to_value(reason).unwrap(), expected);
    }
}

#[test]
fn typed_status_menu_decodes_native_history_and_active_apps() {
    let (mut client, task) = peer(|stream| {
        let frame = read_frame(stream);
        assert_eq!(
            frame["params"]["requestType"],
            "ComputerUseIPCStatusItemMenuStateRequest"
        );
        assert_eq!(frame["params"]["request"], json!({}));
        send(
            stream,
            json!({"id":frame["id"],"jsonrpc":"2.0","result":{
                "computerUse":{"activeApplications":[{"id":"/tmp/Owned.app","name":"Owned","bundleIdentifier":"example.owned"}]},
                "computerHistory":{"state":"paused","canClearHistory":{"lastTenMinutes":true,"lastHour":true,"lastDay":false},
                    "recentApplications":[{"id":"recent","name":"Recent","isExcluded":false,
                        "lastSession":{"startedAt":"2026-01-01T00:00:00Z","canClearHistory":false},
                        "domains":[{"domain":"owned.example","isExcluded":true}]}]}
            }}),
        );
    });
    let menu = client.status_menu().unwrap();
    assert_eq!(
        menu.computer_use.active_applications[0].id,
        "/tmp/Owned.app"
    );
    assert_eq!(menu.computer_history.state, TimelineState::Paused);
    assert!(menu.computer_history.can_clear_history.last_ten_minutes);
    let recent = &menu.computer_history.recent_applications[0];
    assert_eq!(recent.application.id, "recent");
    assert!(recent.last_session.ended_at.is_none());
    assert!(recent.domains[0].is_excluded);
    task.join().unwrap();
}

#[test]
fn typed_messages_image_preserves_attachment_id_and_response_metadata() {
    let (mut client, task) = peer(|stream| {
        let frame = read_frame(stream);
        assert_eq!(
            frame["params"]["requestType"],
            "ComputerUseIPCMessagesReadImageRequest"
        );
        assert_eq!(frame["params"]["request"], json!({"id":"opaque-id"}));
        send(
            stream,
            json!({"id":frame["id"],"jsonrpc":"2.0","result":{
                "data":"AAEC", "mimeType":"image/png", "chatGUID":"owned-chat", "chatDisplayName":"Owned"
            }}),
        );
    });
    let image = client.read_messages_image("opaque-id").unwrap();
    assert_eq!(image.data, "AAEC");
    assert_eq!(image.mime_type, "image/png");
    assert_eq!(image.chat_guid, "owned-chat");
    assert_eq!(image.chat_display_name, "Owned");
    task.join().unwrap();
}

#[test]
fn typed_messages_read_reuses_cursor_and_preserves_optional_fields() {
    let (mut client, task) = peer(|stream| {
        let frame = read_frame(stream);
        assert_eq!(
            frame["params"]["requestType"],
            "ComputerUseIPCMessagesReadMessagesRequest"
        );
        assert_eq!(
            frame["params"]["request"],
            json!({
                "chatGUID":"owned-chat","unreadOnly":true,"fromDate":1.25,"limit":2,"cursor":"opaque"
            })
        );
        send(
            stream,
            json!({"id":frame["id"],"jsonrpc":"2.0","result":{
                "chats":[{"localRef":"0","guid":"owned-chat","displayName":"Owned"}],
                "senders":[{"localRef":"0","handle":"owned@example.test","service":"FutureService"}],
                "messages":[{"chat":"0","sender":"0","date":42,"isUnread":true},
                            {"chat":"0","sender":"me","date":41,"body":"owned","attachments":[{"id":"attachment"}]}]
            }}),
        );
    });
    let mut query = MessagesReadQuery {
        chat_guid: "owned-chat".into(),
        from_date: Some(f64::NAN),
        to_date: None,
        unread_only: true,
        limit: 2,
        cursor: Some("opaque".into()),
    };
    assert!(matches!(
        client.read_messages(&query),
        Err(Error::InvalidInput(_))
    ));
    query.from_date = Some(1.25);
    let page = client.read_messages(&query).unwrap();
    assert_eq!(page.chats[0].local_ref, "0");
    assert_eq!(page.senders[0].service.as_deref(), Some("FutureService"));
    assert!(page.messages[0].body.is_none());
    assert_eq!(
        page.messages[1].attachments.as_ref().unwrap()[0].id,
        "attachment"
    );
    assert!(page.next_cursor.is_none());
    task.join().unwrap();
}

#[test]
fn typed_chat_discovery_decodes_participants_and_page_limits() {
    let (mut client, task) = peer(|stream| {
        let search = read_frame(stream);
        assert_eq!(
            search["params"]["requestType"],
            "ComputerUseIPCMessagesSearchChatsRequest"
        );
        assert_eq!(
            search["params"]["request"],
            json!({"query":"Alice_%","limit":1})
        );
        send(
            stream,
            json!({"id":search["id"],"jsonrpc":"2.0","result":{
                "chats":[{"guid":"owned","displayName":"Alice_%"}],"hasMore":true
            }}),
        );
        let find = read_frame(stream);
        assert_eq!(
            find["params"]["requestType"],
            "ComputerUseIPCMessagesFindChatsRequest"
        );
        assert_eq!(
            find["params"]["request"],
            json!({
                "participants":["alice@example.test"],"exactParticipants":true,"fromDate":42.5,
                "unreadOnly":true,"limit":2
            })
        );
        send(
            stream,
            json!({"id":find["id"],"jsonrpc":"2.0","result":{
                "chats":[{"guid":"owned","displayName":"Alice","service":"iMessage","lastMessageDate":43,
                    "participants":["0"],"unreadCount":1}],
                "participants":[{"localRef":"0","handle":"alice@example.test","name":"Alice","service":"iMessage"}],
                "hasMore":false
            }}),
        );
    });
    let result = client.search_messages_chats("Alice_%", 1).unwrap();
    assert!(result.has_more);
    assert_eq!(result.chats[0].display_name, "Alice_%");
    let result = client
        .find_messages_chats(&MessagesFindChatsQuery {
            participants: vec!["alice@example.test".into()],
            exact_participants: true,
            name: None,
            from_date: Some(42.5),
            to_date: None,
            unread_only: true,
            limit: 2,
        })
        .unwrap();
    assert_eq!(
        result.chats[0].participants[0],
        result.participants[0].local_ref
    );
    assert_eq!(result.chats[0].unread_count, Some(1));
    assert!(!result.has_more);
    task.join().unwrap();
}

#[test]
fn typed_message_search_round_trips_a_page_cursor() {
    let (mut client, task) = peer(|stream| {
        let frame = read_frame(stream);
        assert_eq!(
            frame["params"]["requestType"],
            "ComputerUseIPCMessagesSearchMessagesRequest"
        );
        assert_eq!(
            frame["params"]["request"],
            json!({
                "text":"%_","chatGUIDs":["a","b"],"participants":["owned@example.test"],
                "exactParticipants":true,"toDate":12.5,"limit":1,"cursor":"previous"
            })
        );
        send(
            stream,
            json!({"id":frame["id"],"jsonrpc":"2.0","result":{
                "chats":[{"localRef":"0","guid":"b","displayName":"Owned B"}],
                "senders":[],"messages":[{"chat":"0","sender":"me","body":"%_","date":4}],
                "nextCursor":"next"
            }}),
        );
    });
    let mut query = MessagesSearchQuery {
        text: "%_".into(),
        chat_guids: vec!["a".into(), "b".into()],
        participants: vec!["owned@example.test".into()],
        exact_participants: true,
        from_date: None,
        to_date: Some(f64::INFINITY),
        limit: 1,
        cursor: Some("previous".into()),
    };
    assert!(matches!(
        client.search_messages(&query),
        Err(Error::InvalidInput(_))
    ));
    query.to_date = Some(12.5);
    let page = client.search_messages(&query).unwrap();
    assert_eq!(page.chats[0].guid, "b");
    assert_eq!(page.messages[0].body.as_deref(), Some("%_"));
    assert_eq!(page.next_cursor.as_deref(), Some("next"));
    task.join().unwrap();
}

#[test]
fn typed_messages_activity_preserves_bucket_counts_and_optional_breakdowns() {
    let (mut client, task) = peer(|stream| {
        let frame = read_frame(stream);
        assert_eq!(
            frame["params"]["requestType"],
            "ComputerUseIPCMessagesCountActivityRequest"
        );
        assert_eq!(
            frame["params"]["request"],
            json!({
                "fromDate":10.25,"interval":"day","chatType":"group","chatGUIDs":["owned"],
                "breakdown":"chat","rankBy":"sent","chatLimit":4,"cursor":"opaque"
            })
        );
        send(
            stream,
            json!({"id":frame["id"],"jsonrpc":"2.0","result":{
                "breakdown":"chat","range":{"from":10.25,"to":20},"interval":"day",
                "timeZoneIdentifier":"America/New_York","buckets":[{"from":10.25,"to":20}],
                "matchingChatCount":2,"chats":[{"guid":"owned","displayName":"Owned","service":"iMessage","type":"group",
                    "participants":[],"total":5,"sent":2,"received":3,"countsByBucket":[{"total":5,"sent":2,"received":3}]}],
                "participants":[],"nextCursor":"next"
            }}),
        );
    });
    let mut query = MessagesActivityQuery {
        from_date: Some(f64::NAN),
        to_date: None,
        interval: MessagesActivityInterval::Day,
        chat_type: Some(MessagesActivityChatType::Group),
        chat_guids: vec!["owned".into()],
        breakdown: MessagesActivityBreakdown::Chat,
        rank_by: MessagesActivityRank::Sent,
        chat_limit: 4,
        cursor: Some("opaque".into()),
    };
    assert!(matches!(
        client.count_messages_activity(&query),
        Err(Error::InvalidInput(_))
    ));
    query.from_date = Some(10.25);
    let page = client.count_messages_activity(&query).unwrap();
    assert_eq!(page.matching_chat_count, 2);
    assert!(page.overall_activity.is_none());
    let chats = page.chats.unwrap();
    assert_eq!(chats[0].chat_type, MessagesActivityChatType::Group);
    assert_eq!(chats[0].counts_by_bucket, [chats[0].count.clone()]);
    assert_eq!(page.next_cursor.as_deref(), Some("next"));
    task.join().unwrap();
}

#[test]
fn typed_messages_prepare_send_preserves_text_and_attachment_names() {
    let (mut client, task) = peer(|stream| {
        let frame = read_frame(stream);
        assert_eq!(
            frame["params"]["requestType"],
            "ComputerUseIPCMessagesPrepareSendRequest"
        );
        assert_eq!(
            frame["params"]["request"],
            json!({"recipients":["owned@example.test"],"text":" draft ","attachments":[{"filename":"owned.txt"}]})
        );
        send(
            stream,
            json!({"id":frame["id"],"jsonrpc":"2.0","result":{
                "planID":"A1111111-1111-1111-1111-111111111111","displayName":"Owned",
                "text":" draft ","attachments":[{"filename":"owned.txt"}]
            }}),
        );
    });
    let input = MessagesPrepareSendQuery {
        chat_guid: None,
        recipients: vec!["owned@example.test".into()],
        text: Some(" draft ".into()),
        attachments: vec![MessagesSendAttachment {
            filename: "owned.txt".into(),
        }],
    };
    let prepared = client.prepare_messages_send(&input).unwrap();
    assert_eq!(prepared.plan_id, "A1111111-1111-1111-1111-111111111111");
    assert!(prepared.chat_guid.is_none());
    assert_eq!(prepared.text, input.text);
    assert_eq!(prepared.attachments, input.attachments);
    task.join().unwrap();
}

#[test]
#[cfg(target_os = "macos")]
fn generic_requests_transfer_the_measured_darwin_file_limit() {
    use std::fs::File;
    use std::os::fd::{AsFd, FromRawFd};
    for count in [65, 254] {
        let file = File::open("/dev/null").unwrap();
        let (mut client, task) = peer(move |stream| {
            let mut header = [0; 4];
            // SAFETY: aligned storage covers the kernel's complete rights message.
            let (read, received) = unsafe {
                let space = libc::CMSG_SPACE((count * 4) as _) as usize;
                let mut control = vec![0usize; space.div_ceil(std::mem::size_of::<usize>())];
                let mut payload = libc::iovec { iov_base: header.as_mut_ptr().cast(), iov_len: 4 };
                let mut message: libc::msghdr = std::mem::zeroed();
                message.msg_iov = &mut payload; message.msg_iovlen = 1;
                message.msg_control = control.as_mut_ptr().cast(); message.msg_controllen = space as _;
                let read = libc::recvmsg(stream.as_raw_fd(), &mut message, 0);
                assert!(read > 0);
                assert_eq!(message.msg_flags & libc::MSG_CTRUNC, 0);
                let ancillary = libc::CMSG_FIRSTHDR(&message);
                assert!(!ancillary.is_null());
                assert_eq!((*ancillary).cmsg_level, libc::SOL_SOCKET);
                assert_eq!((*ancillary).cmsg_type, libc::SCM_RIGHTS);
                assert_eq!((*ancillary).cmsg_len as usize, libc::CMSG_LEN((count * 4) as _) as usize);
                let received: Vec<_> = (0..count).map(|index| {
                    File::from_raw_fd(libc::CMSG_DATA(ancillary).cast::<i32>().add(index).read_unaligned())
                }).collect();
                (read as usize, received)
            };
            assert!(received.iter().all(|file| unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFD) } >= 0));
            stream.read_exact(&mut header[read..]).unwrap();
            let mut body = vec![0; u32::from_le_bytes(header) as usize];
            stream.read_exact(&mut body).unwrap();
            let frame: Value = serde_json::from_slice(&body).unwrap();
            assert_eq!(frame["params"]["requestType"], "OwnedFileBoundary");
            assert_eq!(frame["params"]["request"], json!({"count": count}));
            send(stream, json!({"id":frame["id"],"jsonrpc":"2.0","result":received.len()}));
            let recovery = read_frame(stream);
            assert_eq!(recovery["params"]["requestType"], "Recovery");
            send(stream, json!({"id":recovery["id"],"jsonrpc":"2.0","result":true}));
        });
        let files = vec![file.as_fd(); count];
        let accepted: usize = client.request_with_files("OwnedFileBoundary", json!({"count":count}),
                                                       &RequestOptions::default(), &files).unwrap();
        assert_eq!(accepted, count);
        assert!(unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFD) } >= 0);
        assert!(client.request::<bool>("Recovery", json!({})).unwrap());
        task.join().unwrap();
    }
}

#[test]
fn typed_messages_commit_transfers_regular_files_without_paths() {
    use std::fs::{self, File};
    use std::os::fd::AsFd;
    let file_path = env::temp_dir().join(format!("cua-commit-test-{}", std::process::id()));
    let mut owned = fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&file_path)
        .unwrap();
    owned.write_all(b"owned attachment").unwrap();
    let file = File::open(&file_path).unwrap();
    fs::remove_file(&file_path).unwrap();
    let (mut client, task) = peer(|stream| {
        use std::os::fd::FromRawFd;
        let mut header = [0; 4];
        let mut control = [0usize; 8];
        let mut data = libc::iovec {
            iov_base: header.as_mut_ptr().cast(),
            iov_len: header.len(),
        };
        // SAFETY: the control buffer is aligned and both buffers live through recvmsg.
        let (read, fd) = unsafe {
            let mut message: libc::msghdr = std::mem::zeroed();
            message.msg_iov = &mut data;
            message.msg_iovlen = 1;
            message.msg_control = control.as_mut_ptr().cast();
            message.msg_controllen = std::mem::size_of_val(&control) as _;
            let read = libc::recvmsg(stream.as_raw_fd(), &mut message, 0);
            assert!(read > 0);
            let ancillary = libc::CMSG_FIRSTHDR(&message);
            assert!(!ancillary.is_null());
            assert_eq!((*ancillary).cmsg_type, libc::SCM_RIGHTS);
            assert_eq!((*ancillary).cmsg_len as usize, libc::CMSG_LEN(4) as usize);
            (
                read as usize,
                File::from_raw_fd(
                    libc::CMSG_DATA(ancillary)
                        .cast::<libc::c_int>()
                        .read_unaligned(),
                ),
            )
        };
        stream.read_exact(&mut header[read..]).unwrap();
        let mut body = vec![0; u32::from_le_bytes(header) as usize];
        stream.read_exact(&mut body).unwrap();
        let frame: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(
            frame["params"]["requestType"],
            "ComputerUseIPCMessagesCommitSendRequest"
        );
        assert_eq!(
            frame["params"]["request"],
            json!({"planID":"owned-plan","text":"approved"})
        );
        let mut bytes = Vec::new();
        (&fd).read_to_end(&mut bytes).unwrap();
        assert_eq!(bytes, b"owned attachment");
        send(
            stream,
            json!({"id":frame["id"],"jsonrpc":"2.0","result":{
                "destinationKind":"existing_chat","chatGUID":"owned","displayName":"Owned","text":"approved",
                "participants":[],"attachments":[{"filename":"owned.bin"}],"sentAt":42
            }}),
        );
    });
    let query = MessagesCommitSendQuery {
        plan_id: "owned-plan".into(),
        text: Some("approved".into()),
    };
    let files = [file.as_fd(); MAX_FRAME_FILES + 1];
    assert!(matches!(
        client.commit_messages_send(&query, &files),
        Err(Error::InvalidInput(_))
    ));
    let result = client
        .commit_messages_send(&query, &[file.as_fd()])
        .unwrap();
    assert_eq!(
        result.destination_kind,
        MessagesSendDestinationKind::ExistingChat
    );
    assert_eq!(result.chat_guid.as_deref(), Some("owned"));
    assert_eq!(result.attachments[0].filename, "owned.bin");
    task.join().unwrap();
}

#[test]
fn typed_timeline_methods_use_native_routes_and_wire_shapes() {
    let raw_status = json!({"state":"running","startedAt":800_000_000.25,"currentSegmentEventsPath":"/owned/events.jsonl"});
    let raw_settings = json!({"observation":{
        "defaultApplicationBehavior":"observe", "defaultURLBehavior":"do_not_observe",
        "allowlist":[{"scope":"app","bundleID":"com.example.Owned"}],
        "blocklist":[{"scope":"url","urlDomain":"example.invalid"}]
    }});
    let status = raw_status.clone();
    let settings = raw_settings.clone();
    let (mut client, task) = peer(move |stream| {
        for (route, request, response) in [
            ("Start", json!({}), status.clone()),
            ("Status", json!({}), status.clone()),
            ("Pause", json!({}), json!({"state":"paused"})),
            (
                "Pause",
                json!({"duration":"until_tomorrow"}),
                json!({"state":"paused"}),
            ),
            ("Resume", json!({}), status.clone()),
            ("GetSettings", json!({}), settings.clone()),
            (
                "UpdateSettings",
                json!({"settings":settings}),
                settings.clone(),
            ),
            (
                "UpdateObservationPolicy",
                json!({"target":{"scope":"url","urlDomain":"example.invalid"},"observe":false}),
                settings,
            ),
            (
                "ClearHistory",
                json!({"scope":"application_session","interval":{"start":20.0,"end":21.0}}),
                status.clone(),
            ),
            ("ClearHistory", json!({"scope":"last_ten_minutes"}), status),
            (
                "Stop",
                json!({}),
                json!({"state":"stopped","endedAt":800_000_001.5}),
            ),
        ] {
            let frame = read_frame(stream);
            assert_eq!(
                frame["params"]["requestType"],
                format!("ComputerUseIPCTimeline{route}Request")
            );
            assert_eq!(frame["params"]["request"], request);
            send(
                stream,
                json!({"id":frame["id"],"jsonrpc":"2.0","result":response}),
            );
        }
    });

    let status = client.start_timeline().unwrap();
    assert_eq!(status.state, TimelineState::Running);
    assert_eq!(status.started_at, Some(800_000_000.25));
    assert_eq!(status.ended_at, None);
    assert_eq!(
        status.current_segment_events_path.as_deref(),
        Some("/owned/events.jsonl")
    );
    assert_eq!(client.timeline_status().unwrap(), status);
    assert_eq!(
        client.pause_timeline(None).unwrap().state,
        TimelineState::Paused
    );
    assert_eq!(
        client
            .pause_timeline(Some(TimelinePauseDuration::UntilTomorrow))
            .unwrap()
            .state,
        TimelineState::Paused
    );
    assert_eq!(client.resume_timeline().unwrap(), status);
    let settings = client.timeline_settings().unwrap();
    assert_eq!(serde_json::to_value(&settings).unwrap(), raw_settings);
    assert_eq!(
        client.update_timeline_settings(&settings).unwrap(),
        settings
    );
    assert_eq!(
        client
            .update_timeline_observation_policy(&settings.observation.blocklist[0], false)
            .unwrap(),
        settings
    );
    for interval in [
        TimelineHistoryInterval {
            start: f64::NAN,
            end: 2.0,
        },
        TimelineHistoryInterval {
            start: 2.0,
            end: f64::INFINITY,
        },
        TimelineHistoryInterval {
            start: 2.0,
            end: 2.0,
        },
        TimelineHistoryInterval {
            start: 3.0,
            end: 2.0,
        },
    ] {
        assert!(matches!(
            client.clear_timeline_history(TimelineHistoryScope::Interval { interval }),
            Err(Error::InvalidInput(_))
        ));
    }
    let interval = TimelineHistoryInterval {
        start: 20.0,
        end: 21.0,
    };
    assert_eq!(
        client
            .clear_timeline_history(TimelineHistoryScope::ApplicationSession { interval })
            .unwrap(),
        status
    );
    assert_eq!(
        client
            .clear_timeline_history(TimelineHistoryScope::LastTenMinutes)
            .unwrap(),
        status
    );
    let stopped = client.stop_timeline().unwrap();
    assert_eq!(stopped.state, TimelineState::Stopped);
    assert_eq!(stopped.ended_at, Some(800_000_001.5));
    task.join().unwrap();
}

#[test]
fn typed_calendar_methods_use_native_routes_and_wire_shapes() {
    let id = json!({"identifier":"owned","startDate":100.0,"endDate":160.0});
    let event = json!({
        "id":id,"calendarID":"owned-calendar","title":"Owned event","isAllDay":false,
        "attendees":[],"recurrenceRFC2445":"FREQ=DAILY","isCanceled":false,
        "currentUserParticipantStatus":"inProcess","isEditable":true
    });
    let (mut client, task) = peer(move |stream| {
        for route in [
            "ListCalendars",
            "ListEvents",
            "GetEvent",
            "CreateEvent",
            "UpdateEvent",
            "DeleteEvent",
        ] {
            let frame = read_frame(stream);
            assert_eq!(
                frame["params"]["requestType"],
                format!("ComputerUseIPCCalendar{route}Request")
            );
            let request = &frame["params"]["request"];
            let result = match route {
                "ListCalendars" => {
                    assert_eq!(request, &json!({}));
                    json!([{"id":"owned-calendar","title":"Owned","source":{"id":"owned-source","title":"Local"},"allowsContentModifications":true,"isDefault":true}])
                }
                "ListEvents" => {
                    assert_eq!(
                        request,
                        &json!({"calendarIDs":["owned-calendar"],"limit":1,"cursor":"opaque","startDate":90.0,"endDate":200.0})
                    );
                    json!({"events":[event],"nextCursor":"next"})
                }
                "GetEvent" => {
                    assert_eq!(request, &json!({"id":id}));
                    event.clone()
                }
                "CreateEvent" => {
                    assert_eq!(request["title"], "Owned event");
                    assert_eq!(request["calendarID"], "owned-calendar");
                    assert_eq!(request["recurrenceRFC2445"], "FREQ=DAILY");
                    assert_eq!(request["isAllDay"], false);
                    event.clone()
                }
                "UpdateEvent" => {
                    assert_eq!(request["id"], id);
                    assert_eq!(request["span"], "futureEvents");
                    assert_eq!(request["url"], "");
                    assert_eq!(request["attendees"], json!([]));
                    assert!(request["title"].is_null());
                    event.clone()
                }
                _ => {
                    assert_eq!(request, &json!({"id":id,"span":"thisEvent"}));
                    json!({})
                }
            };
            send(
                stream,
                json!({"id":frame["id"],"jsonrpc":"2.0","result":result}),
            );
        }
    });

    let calendars = client.list_calendars().unwrap();
    assert!(calendars[0].is_default);
    let query = CalendarEventsQuery {
        start_date: 90.0,
        end_date: 200.0,
        calendar_ids: vec![calendars[0].id.clone()],
        limit: 1,
        cursor: Some("opaque".into()),
    };
    let page = client.list_calendar_events(&query).unwrap();
    assert_eq!(page.next_cursor.as_deref(), Some("next"));
    let event = client.get_calendar_event(&page.events[0].id).unwrap();
    assert_eq!(
        event.current_user_participant_status,
        Some(CalendarParticipantStatus::InProcess)
    );
    assert_eq!(event.recurrence_rfc2445.as_deref(), Some("FREQ=DAILY"));
    let mut request = CalendarEventCreation {
        title: "Owned event".into(),
        start_date: 100.0,
        is_all_day: false,
        details: CalendarEventDetails {
            calendar_id: Some(calendars[0].id.clone()),
            recurrence_rfc2445: Some("FREQ=DAILY".into()),
            end_date: Some(f64::INFINITY),
            ..Default::default()
        },
    };
    assert!(matches!(
        client.create_calendar_event(&request),
        Err(Error::InvalidInput(_))
    ));
    request.details.end_date = None;
    assert_eq!(client.create_calendar_event(&request).unwrap(), event);
    let patch = CalendarEventPatch {
        details: CalendarEventDetails {
            url: Some("".into()),
            attendees: Some(vec![]),
            ..Default::default()
        },
        ..Default::default()
    };
    assert_eq!(
        client
            .update_calendar_event(&event.id, CalendarEventSpan::FutureEvents, &patch)
            .unwrap(),
        event
    );
    client
        .delete_calendar_event(&event.id, CalendarEventSpan::ThisEvent)
        .unwrap();
    task.join().unwrap();
}

#[test]
fn action_app_snapshot_uses_standard_action_then_observation_requests() {
    let (mut client, task) = peer(|stream| {
        for index in 0..3 {
            let frame = read_frame(stream);
            assert_eq!(frame["params"]["requestType"], "ComputerUseIPCAppPerformActionRequest");
            assert_eq!(frame["params"]["request"], json!({"app":"test.owned","action":{"type":{"_0":"test"}}}));
            send(stream, json!({"id":frame["id"],"jsonrpc":"2.0","result":{"app":{"pid":12,"bundleIdentifier":"test.owned"}}}));
            if index > 0 {
                let frame = read_frame(stream);
                assert_eq!(frame["params"]["requestType"], "ComputerUseIPCAppGetAppSnapshotRequest");
                assert_eq!(frame["params"]["request"], json!({"app":"test.owned","disableDiff":true}));
                let mut shot = json!({"text":"AXButton"});
                if index == 2 { shot["screenshot"] = json!({"url":"file:///private/tmp/owned.jpg","mimeType":"image/jpeg"}); }
                send(stream, json!({"id":frame["id"],"jsonrpc":"2.0","result":{"app":{"pid":12,"bundleIdentifier":"test.owned"},"appSnapshot":shot}}));
            }
        }
    });
    let ordinary = client.perform_action("test.owned", Action::type_text("test")).unwrap();
    assert!(ordinary.get("appSnapshot").is_none());
    let without_image = client.perform_action_with_app_snapshot("test.owned", Action::type_text("test")).unwrap();
    assert_eq!(without_image.app.pid, 12);
    let shot = without_image.appSnapshot;
    assert_eq!(shot.text, "AXButton");
    assert!(shot.screenshot.is_none());
    let with_image = client.perform_action_with_app_snapshot("test.owned", Action::type_text("test")).unwrap();
    let screenshot = with_image.appSnapshot.screenshot.unwrap();
    assert_eq!(screenshot.mime_type, "image/jpeg");
    assert_eq!(screenshot.url, "file:///private/tmp/owned.jpg");
    task.join().unwrap();
}

#[test]
fn action_app_snapshot_stops_on_action_or_capture_error_without_retry() {
    let (mut client, task) = peer(|stream| {
        let first = read_frame(stream);
        assert_eq!(first["params"]["requestType"], "ComputerUseIPCAppPerformActionRequest");
        send(stream, json!({"id":first["id"],"jsonrpc":"2.0","error":{"code":-10004,"message":"owned action failure"}}));
        let second = read_frame(stream);
        assert_eq!(second["params"]["requestType"], "ComputerUseIPCAppPerformActionRequest");
        send(stream, json!({"id":second["id"],"jsonrpc":"2.0","result":{"app":{"pid":12,"bundleIdentifier":"test.owned"}}}));
        let capture = read_frame(stream);
        assert_eq!(capture["params"]["requestType"], "ComputerUseIPCAppGetAppSnapshotRequest");
        send(stream, json!({"id":capture["id"],"jsonrpc":"2.0","error":{"code":-10005,"message":"owned capture failure"}}));
        let next = read_frame(stream);
        assert_eq!(next["params"]["requestType"], "ComputerUseIPCFrontmostWindowRequest");
        send(stream, json!({"id":next["id"],"jsonrpc":"2.0","result":null}));
    });
    assert!(client.perform_action_with_app_snapshot("test.owned", Action::type_text("test")).is_err());
    assert!(client.perform_action_with_app_snapshot("test.owned", Action::type_text("test")).is_err());
    assert!(client.frontmost_window().unwrap().is_none());
    task.join().unwrap();
}
