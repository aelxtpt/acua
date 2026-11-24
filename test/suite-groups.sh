# Group recipes executed independently by review-suite.py.
fail=0
echo "== Swift service self-test =="
(cd service && make selftest bundle) || fail=1
echo; echo "== Socket deadlines, backpressure and connection admission =="
(cd service && make socket-io-test) || fail=1
echo; echo "== Sender authorization: signing policy and kernel peer identity =="
(cd service && make sender-authorization-test sender-request-context-test apple-event-authorization-test sender-client-metadata-test sender-peer-native-build) || fail=1
node test/sender-authorization.mjs || fail=1
echo; echo "== Event stream: contracts and JSONL storage =="
(cd service && make event-stream-storage-test) || fail=1
echo; echo "== Event stream: shared capture lifecycle and native input decoding =="
(cd service && make event-stream-capture-test) || fail=1
echo; echo "== Event stream: application identity and URL policy =="
(cd service && make event-stream-policy-test) || fail=1
echo; echo "== Event stream: accessibility labels and text budgets =="
(cd service && make event-stream-ax-test) || fail=1
echo; echo "== Event stream: transformed presentation and tree text =="
(cd service && make event-stream-rendering-test) || fail=1
echo; echo "== Event stream: visible child selection and array subsets =="
(cd service && make event-stream-children-test) || fail=1
echo; echo "== Event stream: external native child lists and visibility =="
(cd service && make event-stream-children-native-build && /tmp/cua-event-stream-children-native) || fail=1
echo; echo "== Event stream: batch attributes and transaction snapshots =="
(cd service && make event-stream-snapshots-test) || fail=1
echo; echo "== Shared synthesized event numbering and transaction cache views =="
(cd service && make synthesized-events-test) || fail=1
echo; echo "== Event stream: hierarchy partial values and scoped native transactions =="
(cd service && make event-stream-hierarchy-test) || fail=1
echo; echo "== Event stream: transformed values, editing and truncation =="
(cd service && make event-stream-value-test) || fail=1
echo; echo "== Event stream: native transformed node fields, capabilities and actions =="
(cd service && make event-stream-node-test) || fail=1
echo; echo "== Event stream: native tree collection, identity and child subsets =="
(cd service && make event-stream-tree-collection-test) || fail=1
echo; echo "== Event stream: whole-tree pipelines, nested focus and cache/table ownership =="
(cd service && make event-stream-tree-transformation-test) || fail=1
echo; echo "== Event stream: native transformation context, app traits and window geometry =="
(cd service && make event-stream-transformation-context-test) || fail=1
echo; echo "== Event stream: native node renderer, inclusive table ranges and URL state =="
(cd service && make event-stream-native-renderer-test) || fail=1
echo; echo "== Event stream: native selected sources and focused tree recovery =="
(cd service && make event-stream-tree-focus-test) || fail=1
echo; echo "== Event stream: external native selected table rows and focus recovery =="
(cd service && make event-stream-tree-focus-native-build && /tmp/cua-event-stream-tree-focus-native) || fail=1
echo; echo "== Event stream: recursive rich URL trimming and cache ownership =="
(cd service && make event-stream-tree-url-trimming-test) || fail=1
echo; echo "== Event stream: render forest promotion, source paths and partial-list details =="
(cd service && make event-stream-render-forest-test) || fail=1
echo; echo "== Event stream: render ID allocation, focus mapping and source lookup =="
(cd service && make event-stream-render-ids-test) || fail=1
echo; echo "== Event stream: render difference, ordering, inheritance and counters =="
(cd service && make event-stream-render-difference-test) || fail=1
echo; echo "== Event stream: revision construction, failure order, lineage and value snapshots =="
(cd service && make event-stream-tree-revision-test) || fail=1
echo; echo "== Event stream: revision difference line budgets, removal summaries and inspector payload =="
(cd service && make event-stream-revision-difference-lines-test) || fail=1
echo; echo "== Event stream: screenshot context policy and native selection description =="
(cd service && make event-stream-capture-context-policy-test) || fail=1
echo; echo "== Event stream: native capture transformation phases and URL accounting =="
(cd service && make event-stream-capture-transformation-test) || fail=1
echo; echo "== Event stream: raw capture cache focus menu and metadata owner =="
(cd service && make event-stream-capture-core-test) || fail=1
echo; echo "== Event stream: invalidation monitor state registration and worker teardown =="
(cd service && make event-stream-invalidation-monitor-test) || fail=1
echo; echo "== Event stream: real native layout and destroyed-element observations =="
(cd service && make event-stream-invalidation-monitor-native-build && /tmp/cua-event-stream-invalidation-monitor-native) || fail=1
echo; echo "== Event stream: parent cache transaction enablement cleanup and selection output =="
(cd service && make event-stream-selection-extractor-test) || fail=1
echo; echo "== Event stream: recorder metadata prefetch and post-render state ordering =="
(cd service && make event-stream-recorder-metadata-test) || fail=1
echo; echo "== Event stream: application transition policy observer replacement and retries =="
(cd service && make event-stream-application-controller-test) || fail=1
echo; echo "== Event stream: existing running application metadata and nil field ordering =="
(cd service && make event-stream-running-application-metadata-test) || fail=1
echo; echo "== Event stream: recorder notification membership registration errors and debounce policy =="
(cd service && make event-stream-recorder-observation-policy-test) || fail=1
echo; echo "== Event stream: per-key notification cancellation replacement and reentrant flush =="
(cd service && make event-stream-notification-queue-test) || fail=1
echo; echo "== Event stream: selection records ranges item projection and coalescing keys =="
(cd service && make event-stream-selection-record-builder-test) || fail=1
echo; echo "== Event stream: native observer callback payload and Foundation dictionary bridge =="
(cd service && make event-stream-observer-payload-test) || fail=1
echo; echo "== Event stream: native selection providers and callback source snapshots =="
(cd service && make event-stream-native-selection-records-test) || fail=1
echo; echo "== Event stream: real Unicode text selected rows and callback snapshots =="
(cd service && make event-stream-native-selection-records-native-build && /tmp/cua-event-stream-native-selection-records-native) || fail=1
echo; echo "== Event stream: terminal membership secure input debounce and target refresh =="
(cd service && make event-stream-terminal-test) || fail=1
echo; echo "== Event stream: recorder observer setup worker delivery and weak ownership =="
(cd service && make event-stream-recorder-observation-test) || fail=1
echo; echo "== Event stream: recorder lifecycle shared sequence subscriptions and timers =="
(cd service && make event-stream-recorder-lifecycle-test) || fail=1
echo; echo "== Event stream: native notification dispatch focused window and owner flush =="
(cd service && make event-stream-recorder-notifications-test) || fail=1
echo; echo "== Event stream: composed native producer shared owners and delayed lifetime =="
(cd service && make event-stream-native-producer-test) || fail=1
echo; echo "== Event stream: recording sessions storage cancellation and automatic deadline =="
(cd service && make event-stream-recording-service-test) || fail=1
echo; echo "== Event stream: native blocked-site warning presentation and dismissal =="
(cd service && make event-stream-recording-warning-native-test) || fail=1
echo; echo "== Event stream: native recording timer panel and controls =="
(cd service && make event-stream-recording-overlay-native-test) || fail=1
echo; echo "== Event stream: native recording status artwork and menu =="
(cd service && make event-stream-recording-status-native-test) || fail=1
echo; echo "== Event stream: telemetry scope and recording wire dates =="
(cd service && make event-stream-telemetry-wire-test) || fail=1
echo; echo "== Event stream: native recording IPC subscription storage and lifecycle =="
(cd service && make event-stream-ipc-native-build) && CUA_NATIVE_PRODUCER_BINARY=/tmp/cua-event-stream-ipc-native node test/event-stream-native-producer-native.mjs || fail=1
echo; echo "== Event stream: production socket routes and metadata validation =="
node test/event-stream-ipc-protocol.mjs || fail=1
echo; echo "== Event stream: recording URL policy cache, local privacy blocklist and file filtering =="
(cd service && make event-stream-recording-url-test) || fail=1
echo; echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo; echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo; echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo; echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo; echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo; echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo; echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo; echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo; echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo; echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo; echo "== Native PIP window ownership: typed-argument corpus =="
(cd service && make native-pip-window-ownership-test) || fail=1
echo; echo "== Native PIP XPC: interfaces and separate-process roundtrips =="
(cd service && make native-pip-xpc-test) || fail=1
echo; echo "== Computer Use XPC: session admission, descriptors and foreground updates =="
(cd service && make computer-use-xpc-test xpc-session-admission-test) || fail=1
echo; echo "== Native PIP connection: lifecycle states and anonymous listener admission =="
(cd service && make native-pip-connection-test) || fail=1
echo; echo "== Native PIP producer: commands, queue lifetime and separate-process owner =="
(cd service && make native-pip-producer-test) || fail=1
echo; echo "== Native PIP controller: turn lifecycle and window ownership =="
(cd service && make native-pip-controller-test) || fail=1
echo; echo "== Native PIP window: live frames and associated-window changes =="
(cd service && make native-pip-window-build && python3 -c 'import subprocess,sys; sys.exit(subprocess.run(["/tmp/cua-native-pip-window-tests"], timeout=18).returncode)') || fail=1
echo; echo "== Native PIP focus: window activation and restoration over XPC =="
(cd service && make native-pip-focus-build && python3 -c 'import subprocess,sys; sys.exit(subprocess.run(["/tmp/cua-native-pip-focus-tests"], timeout=30).returncode)') || fail=1
echo; echo "== Native PIP graphics: layer pixels, fence ownership and XPC transfer =="
(cd service && make native-pip-layer-context-test) || fail=1
echo; echo "== Native PIP checkerboard: pixels, animation, async operations and errors =="
(cd service && make native-pip-checkerboard-test) || fail=1
echo; echo "== Event stream: real native producer tap observer capture stop and restart =="
(cd service && make event-stream-native-producer-native-build && node ../test/event-stream-native-producer-native.mjs) || fail=1
echo; echo "== Event stream: subtree and disabled-leaf pruning =="
(cd service && make event-stream-pruning-test) || fail=1
echo; echo "== Event stream: shared group merge and redundant hierarchy transform =="
(cd service && make event-stream-shared-transform-test) || fail=1
echo; echo "== Event stream: selectable ancestor flattening and retained boolean controls =="
(cd service && make event-stream-selectable-transform-test) || fail=1
echo; echo "== Event stream: title association, native identity and sibling regrouping =="
(cd service && make event-stream-title-association-test) || fail=1
echo; echo "== Event stream: Mac action filtering, native leaf pruning and Calendar transform =="
(cd service && make event-stream-mac-transform-test) || fail=1
echo; echo "== Event stream: attributed AX range and text-marker acquisition =="
(cd service && make event-stream-attributed-acquisition-test) || fail=1
echo; echo "== Event stream: attributed Markdown styles, attachments and source positions =="
(cd service && make event-stream-attributed-markdown-test) || fail=1
echo; echo "== Event stream: external native attributed text and WebKit markers =="
(cd service && make event-stream-attributed-native-build && /tmp/cua-event-stream-attributed-native) || fail=1
echo; echo "== Event stream: repetitive text and captured boolean value projection =="
(cd service && make event-stream-repetitive-text-test) || fail=1
echo; echo "== Event stream: rich transformed strings and UTF-16 source maps =="
(cd service && make event-stream-transformed-string-test) || fail=1
echo; echo "== Event stream: URL shortening, budgets and compaction =="
(cd service && make event-stream-url-shortener-test) || fail=1
echo; echo "== Event stream: Markdown link labels and URL spans =="
(cd service && make event-stream-markdown-link-test) || fail=1
echo; echo "== Event stream: link-to-static-text transformation =="
(cd service && make event-stream-link-transform-test) || fail=1
echo; echo "== Event stream: native text sibling runs and context-aware links =="
(cd service && make event-stream-text-siblings-test) || fail=1
echo; echo "== Event stream: external native snapshot cache and refresh =="
(cd service && make event-stream-snapshots-native-build && /tmp/cua-event-stream-snapshots-native) || fail=1
echo; echo "== Event stream: external native AX labels, values and secure fields =="
(cd service && make event-stream-ax-native-build && node ../test/event-stream-ax-native.mjs) || fail=1
echo; echo "== Event stream: ordered policy queue and recording commits =="
(cd service && make event-stream-records-test) || fail=1
echo; echo "== Event stream: text grouping, AX refresh and debounce cancellation =="
(cd service && make event-stream-text-test) || fail=1
echo; echo "== Event stream: pointer and keyboard interaction record preparation =="
(cd service && make event-stream-interaction-test) || fail=1
echo; echo "== Event stream: native context selection and URL cache =="
(cd service && make event-stream-context-test) || fail=1
echo; echo "== Event stream: disposable native context fixture =="
(cd service && make event-stream-context-native-build && /tmp/cua-event-stream-context-native) || fail=1
echo; echo "== Event stream: tracked foreground identity and fallback =="
(cd service && make event-stream-frontmost-test) || fail=1
echo; echo "== Event stream: real input tap, native text and JSONL =="
(cd service && make event-stream-text-native-build && node ../test/event-stream-text-native.mjs) || fail=1
echo; echo "== Event stream: final record assembly and changed-target capture =="
(cd service && make event-stream-factory-test) || fail=1
echo; echo "== Synthetic focus: activation packets and state =="
(cd service && make synthetic-focus-test) || fail=1
echo; echo "== System keyboard focus: theft, return and routing state =="
(cd service && make system-keyboard-focus-test) || fail=1
echo; echo "== Hosted focus: native repair decisions and owned receiver notices =="
(cd service && make hosted-focus-repair-test hosted-focus-repair-native-test) || fail=1
echo; echo "== Bounded parent traversal and prefetch =="
(cd service && make ax-parent-chain-test) || fail=1
echo; echo "== Screenshot coordinate geometry =="
(cd service && make geometry-test offscreen-spi-test) || fail=1
echo; echo "== Multiple-window capture layout and crop coordinates =="
(cd service && make capture-layout-test) || fail=1
echo; echo "== Ordered pointer targets and hosted process ancestry =="
(cd service && make window-target-test) || fail=1
echo; echo "== Native AX/WindowServer target metadata (no input) =="
(cd service && make window-target-native-test) || fail=1
echo; echo "== Native Agent cursor-window identification =="
(cd service && make action-cursor-policy-test selection-cursor-test cursor-capture-test cursor-artwork-test) || fail=1
echo; echo "== Text selection, click options, key chords and request runtime =="
(cd service && make input-test frame-encoding-test socket-jsonrpc-test typed-app-body-test request-activity-test app-policy-test computer-use-policy-test mouse-click-events-test native-click-policy-test secondary-action-test delegated-request-body-test socket-response-body-test) || fail=1
python3 test/selected-request-runtime.py || fail=1
echo; echo "== Native coordinate click: target context, awaited movement and mouse preparation =="
(cd service && make coordinate-click-test) || fail=1
echo; echo "== Native scroll: distance, wheel factory and controller dispatch =="
(cd service && make native-scroll-test) || fail=1
node test/computer-use-policy-ipc.mjs || fail=1
(cd service && make codec-boundary-harness-build) && python3 test/delegated-request-body-wire.py && python3 test/runtime-error-wire.py && python3 test/socket-dispatch-errors.py && python3 test/socket-response-wire.py || fail=1
echo; echo "== Accessibility revisions and stale-control recovery =="
(cd service && make tree-test) || fail=1
echo; echo "== Visible clickable geometry =="
(cd service && make clickable-test) || fail=1
echo; echo "== Automation session lifecycle =="
(cd service && make session-test) || fail=1
echo; echo "== User intervention: event filtering and session targeting =="
(cd service && make intervention-test) || fail=1
echo; echo "== Asynchronous capture ownership =="
(cd service && make pending-test) || fail=1
echo; echo "== Capture protocol stages, cancellation and concurrent delivery =="
(cd service && make capture-stream-test) || fail=1
echo; echo "== Capture coordination and file publication =="
(cd service && make capture-coordinator-test) || fail=1
echo; echo "== Capture transition geometry and lifecycle =="
(cd service && make capture-transition-test) || fail=1
echo; echo "== Native Start/Next capture: stages and real pixels =="
node test/app-capture.mjs || fail=1
echo; echo "== Client request-shape contract =="
node test/shapes.mjs || fail=1
echo; echo "== Screenshot coordinates: real click, scroll and drag =="
node test/coordinates.mjs || fail=1
echo; echo "== Input: real text selection, special clicks and targeted keyboard =="
node test/input.mjs || fail=1
echo; echo "== Synthetic focus: native background keyboard, paste and lifecycle =="
(cd service && make synthetic-focus-probe-build) || fail=1
node test/synthetic-focus.mjs || fail=1
echo; echo "== Persistent focus filters: real panel theft, keyboard rerouting and cleanup =="
(cd service && make focus-preventer-native-build) && node test/focus-preventer.mjs || fail=1
echo; echo "== Focus restoration: foreign input, window order and failure cleanup =="
(cd service && make focus-restoration-native-build) || fail=1
node test/focus-restoration.mjs || fail=1
echo; echo "== Paste: real formats, consumption and clipboard ownership =="
(cd service && make markdown-html-test) || fail=1
python3 test/markdown-rich.py || fail=1
node test/paste.mjs || fail=1
echo; echo "== Protocol end-to-end (live socket) =="
node test/protocol.mjs || fail=1
echo; echo "== Protocol: malformed frames, disconnects and deadlines =="
node test/protocol-edge.mjs || fail=1
echo; echo "== Protocol: real 30-second deadlines and connection admission =="
node test/protocol-resources.mjs || fail=1
echo; echo "== Session lifecycle: real socket, stop and invalid modifications =="
(cd service && make app-usage-catalog-test) || fail=1
node test/lifecycle.mjs || fail=1
python3 test/native-stop-failure.py || fail=1
echo; echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo; echo "== Audio pipeline =="
(cd service && make audio-lifecycle-test audio-reentrant-test audio-shutdown-phases-test audio-start-suspension-test audio-unclaimed-expiry-test audio-native-start-test audio-prepared-deadline-test audio-pcm-test) || fail=1
node test/audio.mjs || fail=1
echo; echo "== End-to-end smoke =="
node test/e2e.mjs || fail=1
echo; echo "== Rust library: protocol, framing, deadlines and typed actions =="
cargo test --offline --locked --manifest-path rust/cua-client/Cargo.toml || fail=1
echo; echo "== Rust library: real service and disposable native fixture =="
node test/rust-client.mjs || fail=1
echo; echo "== Generic serial queue: results, errors, cancellation and priority escalation =="
(cd service && make async-serial-queue-test async-queue-lifecycle-test) || fail=1
echo; echo "== Timeline: wire and rule normalization =="
(cd service && make timeline-wire-test) || fail=1
echo; echo "== Timeline: app URL and domain matching =="
(cd service && make timeline-matching-test) || fail=1
echo; echo "== Timeline: pause dates across DST and calendars =="
(cd service && make timeline-pause-test) || fail=1
echo; echo "== Timeline: invalid history requests and NSError envelope =="
(cd service && make timeline-history-test) || fail=1
echo; echo "== Timeline: history intervals and session clamping =="
(cd service && make timeline-history-interval-test) || fail=1
echo; echo "== Timeline: segment storage restore expiry and deletion =="
(cd service && make timeline-segment-store-test) || fail=1
echo; echo "== Timeline: writer initialization and metadata recovery =="
(cd service && make timeline-writer-initialization-test) || fail=1
echo; echo "== Timeline: writer rotation and finalization =="
(cd service && make timeline-writer-lifecycle-test) || fail=1
echo; echo "== Timeline: writer history deletion and recovery errors =="
(cd service && make timeline-writer-clear-test) || fail=1
echo; echo "== Timeline: writer event bytes counters and compact Codable =="
(cd service && make timeline-writer-append-test) || fail=1
echo; echo "== Timeline: native settings persistence recovery and cache =="
(cd service && make timeline-settings-storage-test) || fail=1
echo; echo "== Timeline: native settings updates notifications and change classification =="
(cd service && make timeline-settings-update-test) || fail=1
echo; echo "== Timeline: native application and domain policy mutations =="
(cd service && make timeline-settings-policy-test) || fail=1
echo; echo "== Timeline: structured settings events and envelopes =="
(cd service && make timeline-settings-telemetry-test) || fail=1
echo "== Timeline: stopped owner and preference effects =="
(cd service && make timeline-lifecycle-stopped-test) || fail=1
echo "== Timeline: paused start reschedule stop and I/O recovery =="
(cd service && make timeline-lifecycle-paused-test) || fail=1
echo "== Timeline: continuous-clock resume and cancellation =="
(cd service && make timeline-resume-scheduler-test) || fail=1
echo "== Timeline: asynchronous queue suppression and recent applications =="
(cd service && make timeline-record-processing-test) || fail=1

echo '== Timeline: memory summary listing overlap and deletion =='
(cd service && make timeline-memory-storage-test) || fail=1

echo "== Timeline service composition =="
(cd service && make timeline-service-test) || fail=1

echo "== Timeline production IPC =="
node test/timeline-ipc-protocol.mjs || fail=1
echo; echo "== Native automation: rendered IDs selection and control recovery =="
(cd service && make native-automation-test native-web-form-test native-hosted-panel-test native-deep-hierarchy-test native-press-error-test element-validation-test native-url-policy-thread-test) || fail=1

echo "== Calendar: isolated permission, event operations and cancellation =="
(cd service && make calendar-service-test) || fail=1
echo "== Calendar: production IPC routing =="
node test/calendar-ipc-protocol.mjs || fail=1
echo "== Messages: isolated chat discovery, pages, attachments and IPC validation =="
(cd service && make messages-read-image-test messages-read-page-test messages-chat-discovery-test messages-send-plans-test) || fail=1
node test/messages-ipc-protocol.mjs || fail=1
echo "== System Settings: destination URL construction =="
(cd service && make system-settings-test) || fail=1
echo "== System Settings: transition geometry =="
(cd service && make system-settings-transition-test) || fail=1

echo "== System Settings: scalar spring =="
(cd service && make system-settings-spring-test) || fail=1

echo "== System Settings: animation events and display link =="
(cd service && make system-settings-animation-test) || fail=1

echo "== Deployment target and artifact/cache metadata =="
(cd service && make deployment-target-check) || fail=1

echo "== System Settings: image appearance and offscreen replicant layers =="
(cd service && make system-settings-appearance-test) || fail=1

echo "== System Settings: shared transition lifecycle and foreground rendering =="
(cd service && make settings-accessory-test) || fail=1

echo "== System Settings: hidden accessory, native tracking and drag/data provider =="
(cd service && make settings-accessory-native-test) || fail=1
echo "== WindowServer: shared native notification ownership =="
(cd service && make window-server-notification-requests-test) || fail=1
echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo "== Screen lock: current-user console fallback and unavailable state =="
(cd service && make screen-lock-state-test) || fail=1
echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo "== Permissions: catalogue values and weak row registry =="
(cd service && make permission-catalogue-registry-test) || fail=1
echo "== Retired group =="
# The code this group tested was removed; the slot keeps later group numbers stable.
echo "This group was retired with the code it tested" >&2; fail=1
echo "== Permissions: shared service state and pending/dismissal =="
(cd service && make service-permissions-test) || fail=1
echo; echo "== ACUA configuration: config.toml parsing, validation and local app policy =="
(cd service && make acua-configuration-test computer-use-policy-test app-policy-test) || fail=1
echo; echo "== ACUA standalone: local policy over IPC, no external agent CLI, no agent config writes, no network =="
node test/computer-use-policy-ipc.mjs || fail=1
echo; echo "== Native in-process checks: coordinates, actions, targets, errors, screenshots, launch state, windows and default policy =="
python3 test/native-in-process-checks.py || fail=1
echo; echo "== ACUA turn contract and Unicode typing: session tracking, _meta turn scope, end_turn and keyless characters =="
(cd service && make acua-turn-contract-test acua-keyboard-text-test acua-mouse-target-test acua-scroll-reveal-test) || fail=1
node test/mcp-turn-contract.mjs || fail=1
echo; echo "== ACUA turn contract: real service user stop, turn end and session end =="
node test/turn-contract.mjs || fail=1
echo; echo "== ACUA app approval without elicitation: [apps].allow, service dialog decisions and case-insensitive app lists =="
(cd service && make acua-app-approval-test acua-mcp-approval-test acua-configuration-test) || fail=1
node test/app-approval.mjs || fail=1
echo; echo "== ACUA app approval dialog: real service dialog opens, closes when its client exits, no dialog for dead queued clients =="
node test/app-approval-dialog.mjs || fail=1
echo; echo "== ACUA mcp install: host snippets, mcpServers file edits and written entries that start real MCP servers =="
(cd service && make acua-mcp-install-test) || fail=1
node test/mcp-install.mjs || fail=1
echo; echo "== ACUA screenshot limits: [screenshots] resolution and max_image_bytes, base64 image content and instructions once per app =="
(cd service && make acua-configuration-test acua-screenshot-budget-test acua-mcp-output-test) || fail=1
echo; echo "== ACUA screenshot limits: real service fitted default, PNG fallback, native resolution and clicks from fitted images =="
node test/screenshot-limits.mjs || fail=1
echo; echo "== ACUA hooks: agent-process sessions, hooks install and uninstall for Claude Code, Cursor and Codex, turn-ended --agent-process =="
(cd service && make acua-agent-process-test acua-hooks-install-test) || fail=1
node test/hooks-install.mjs || fail=1
echo; echo "== ACUA MCP protocol: initialize, 31-tool schema snapshot, protocol and argument errors, elicitation only when declared and never past a cancellation =="
(cd service && make acua-mcp-elicitation-test acua-approval-form-test) || fail=1
node test/mcp-protocol.mjs || fail=1
echo; echo "== ACUA MCP approvals: real service elicitation decline and cancel, cancelled tool calls get no response, elicitation over HTTP, and the service dialog for clients without elicitation =="
node test/mcp-elicitation.mjs || fail=1
echo; echo "== ACUA MCP over HTTP: loopback only, token, path, Origin and session checks, independent sessions and DELETE =="
(cd service && make acua-mcp-http-test) || fail=1
node test/mcp-http.mjs || fail=1
echo; echo "== ACUA with Claude Code: claude -p types into and clicks a disposable app through the MCP tools, and the Stop hook from hooks install ends its session =="
node test/claude-code-e2e.mjs || fail=1
echo; echo "== Second display: screenshot-pixel click, drag, scroll and slider on a display other than the primary one, through the real service =="
node test/coordinates-other-display.mjs || fail=1
echo; echo "== Release signature: hardened runtime, secure timestamp, exact entitlements, product version, and DYLD injection refused by the shipped service =="
(cd service && make bundle-signing-test) || fail=1
python3 test/release-signature.py || fail=1
exit $fail
