# Aex Computer Use (ACUA): macOS computer-use service, MCP helper and tests
.DEFAULT_GOAL := build
SWIFTC ?= swiftc
SWIFTFLAGS ?= -O
SWIFT_MODULE_CACHE ?= /private/tmp/cua-swift-module-cache
MACOSX_DEPLOYMENT_TARGET ?= 14.4
SWIFT_TARGET ?= $(shell uname -m)-apple-macosx$(MACOSX_DEPLOYMENT_TARGET)
DEPLOYMENT_FLAGS = -target "$(SWIFT_TARGET)"
# The legacy component fixtures (the $(SOURCES) set) compile older copies of
# service files; they need the TOML module for ~/.acua/config.toml.
LEGACY_FIXTURE_FLAGS = $(TOML_FLAGS)
# Resolved once per make invocation, on first use, so unrelated targets do not
# pay for it.
TOML_DIR = $(eval TOML_DIR := $$(shell $(NATIVE_BUILD) --print-toml-module | tail -n 1))$(TOML_DIR)
TOML_FLAGS = -I "$(TOML_DIR)" "$(TOML_DIR)/libCUAToml.a" -lc++
CODESIGN ?= codesign
CODESIGN_IDENTITY ?= -
NATIVE_BUILD_DIR ?= $(CURDIR)/.build/current
NATIVE_BUILD = python3 build_native.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)" --target "$(SWIFT_TARGET)" --module-cache "$(SWIFT_MODULE_CACHE)" --build-dir "$(NATIVE_BUILD_DIR)" --output "$(BIN)" --codesign "$(CODESIGN)" --identity "$(CODESIGN_IDENTITY)"
# Stand-alone component fixtures retain their existing shared source set.
SOURCES = main.swift Protocol.swift SocketIO.swift Apps.swift AppSessions.swift AppLifecycle.swift AppCaptureProtocol.swift AppCaptureStore.swift ResponseDelivery.swift AppCaptureCoordinator.swift NativeAppCapture.swift NativeCaptureTransition.swift CaptureTransitionGeometry.swift NativeTargetPolicy.swift AX.swift AXTree.swift TreeRevision.swift AXSettler.swift AXClickableTarget.swift ClickableGeometry.swift Capture.swift CaptureLayout.swift CursorCapture.swift PendingResult.swift NativePaste.swift Actions.swift AudioCaptureBridge.swift Audio.swift CursorOverlay.swift CursorArtwork.swift ScreenshotGeometry.swift MouseTargeting.swift AXPointerTarget.swift AccessibilityWindowSPI.swift TextSelection.swift KeyChord.swift RequestRuntime.swift UserInteraction.swift UserInteractionMonitor.swift SyntheticFocus.swift SyntheticFocusEvents.swift FocusRestorationPolicy.swift FocusRestoration.swift WindowServerUpdates.swift KeyboardFocusSPI.swift SystemKeyboardFocusState.swift KeyboardFocusResolver.swift FocusStealPreventer.swift SenderAuthorization.swift
SOURCES += NativeMouseClick.swift NativeClickFocusPolicy.swift AXNativeClickFocus.swift
SOURCES += NativeMenuClick.swift
SOURCES += NativeCoordinateConversion.swift
SOURCES += NativeScroll.swift ScrollEventFactory.swift
SOURCES += RequestPreparation.swift RequestActivity.swift NativeRequestActivity.swift
SOURCES += SenderRequestContext.swift
SOURCES += XPCSessionAdmission.swift
SOURCES += AppleEventAuthorization.swift
SOURCES += SystemSettings.swift
SOURCES += EventStreamProtocol.swift EventStreamJSONLWriter.swift EventStreamCaptureCoordinator.swift EventStreamInputPolicy.swift EventStreamInputTap.swift
SOURCES += AppUsageCatalog.swift
SOURCES += SocketResponseBody.swift
SOURCES += EventStreamApplicationResolver.swift EventStreamURLPolicy.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift
SOURCES += EventStreamRecordProcessor.swift EventStreamTextInputRecorder.swift EventStreamStorageConfiguration.swift EventStreamRecordingService.swift EventStreamRecordingControls.swift EventStreamRecordingWarning.swift EventStreamRecordingOverlay.swift EventStreamRecordingStatusView.swift
SOURCES += EventStreamRecordingURLPolicy.swift ActionAppSnapshotURLPolicy.swift
SOURCES += AppSpecificInstructions.swift
SOURCES += AXMenuSessions.swift AXMenuWindowOrder.swift AXWindowOrderingObserver.swift AXAccessibility.swift AXVoiceOverPreference.swift
SOURCES += NativeAppSnapshotImage.swift
SOURCES += StageManagerCapture.swift
SOURCES += NativeAppshotPermissions.swift AppshotPermissionAccessory.swift AppshotPermissionTransition.swift AppshotPermissionArrow.swift
SOURCES += SystemSettingsTransitionGeometry.swift
SOURCES += SystemSettingsTransitionAppearance.swift SystemSettingsTransitionReplicantView.swift
SOURCES += SettingsAccessoryCapture.swift SettingsTransitionController.swift SystemSettingsTransitionAnimationBinding.swift
SOURCES += SystemSettingsAccessoryForeground.swift
SOURCES += SettingsAccessoryLayout.swift SystemSettingsAccessoryWindow.swift SystemSettingsAccessoryDrag.swift
SOURCES += WindowServerNotificationRequests.swift
SOURCES += SystemSettingsNativeApplication.swift SystemSettingsPoll.swift SystemSettingsWindowRecord.swift SystemSettingsWindowTracker.swift SystemSettingsWindowNativeEnvironment.swift
SOURCES += SettingsWindowServerObservation.swift SettingsScrollRegistration.swift SettingsScrollNativeEnvironment.swift SettingsAudioHeading.swift SettingsAudioHeadingAX.swift SettingsNativeTrackingBindings.swift
SOURCES += SettingsAccessoryPresentation.swift SettingsTransitionPresentationAdapter.swift SettingsAccessoryTrackingSession.swift
SOURCES += ScreenLockState.swift
SOURCES += SystemSettingsAccessCoordinator.swift SystemSettingsOpen.swift SystemSettingsNativeOpen.swift SystemSettingsAccessNativeEnvironment.swift SystemSettingsAccessWindowRecords.swift SettingsAccessoryNativeBinding.swift NativeSystemSettingsPrivacyPermission.swift
SOURCES += ServicePermissionTypes.swift AppshotPermissionResult.swift ServiceSystemPermissions.swift PermissionWindowServiceAdapter.swift
SOURCES += PermissionCatalog.swift PermissionRowRegistry.swift PermissionRowRegistryNative.swift PermissionRowProbes.swift
SOURCES += PermissionWindowCoordinator.swift PermissionWindowNativeHost.swift PermissionNativeStatus.swift PermissionSettingsRequester.swift
SOURCES += PermissionWindowViewState.swift PermissionWindowContent.swift AppshotPermissionWindow.swift

SOURCES += SystemSettingsScalarSpring.swift
SOURCES += SystemSettingsSpringAnimation.swift SystemSettingsDisplayLinkDriver.swift SystemSettingsSpringDriverBinding.swift
SOURCES += RemoteHostedPIPWindowOwnership.swift
SOURCES += RemoteHostedPIPXPC.swift
SOURCES += ComputerUseXPC.swift ComputerUseXPCBootstrap.swift ComputerUseNativeForegroundMonitor.swift
SOURCES += RemoteHostedPIPConnection.swift
SOURCES += AsyncSerialQueue.swift RemoteHostedPIPContentPublisher.swift
SOURCES += RemoteHostedPIPLayerContext.swift RemoteHostedPIPCheckerboardRenderer.swift RemoteHostedPIPContentStream.swift RemoteHostedPIPVideoEncoder.swift
SOURCES += RemoteHostedPIPWindowRenderer.swift RemoteHostedPIPWindowGeometryObserver.swift RemoteHostedPIPWindowServerObserver.swift RemoteHostedPIPWindowFocus.swift ApplicationRegistrySPI.swift RemoteHostedPIPController.swift
SOURCES += EventStreamInteractionPolicy.swift EventStreamInputRecordBuilder.swift
SOURCES += AXParentChain.swift EventStreamContextResolver.swift WindowDescription.swift EventStreamNativeContext.swift
SOURCES += KeyboardReleaseDelivery.swift
SOURCES += EventStreamRecordFactory.swift EventStreamAXCapture.swift EventStreamFrontmostTracker.swift
SOURCES += EventStreamPresentation.swift EventStreamTreeRendering.swift
SOURCES += EventStreamChildren.swift EventStreamNativeChildren.swift
SOURCES += EventStreamElementSnapshots.swift EventStreamNativeSnapshots.swift EventStreamHierarchySPI.swift EventStreamHierarchyCapture.swift EventStreamTreeTransaction.swift
SOURCES += NativeAutomationTree.swift EventStreamElementValidation.swift NativeAppshotText.swift
SOURCES += HostedFocusRepair.swift
SOURCES += SocketJSONRPC.swift
SOURCES += AppUsageBody.swift
SOURCES += ComputerUsePolicy.swift Native/authenticated-policy-ordering/ComputerUsePolicyIPC.swift Native/authenticated-policy-ordering/ServiceRequestPolicyDecision.swift
SOURCES += Configuration/AcuaConfiguration.swift Configuration/AcuaConfigurationLoader.swift Configuration/AcuaSettings.swift Configuration/DiscardedTelemetry.swift
SOURCES += MouseClickEventFactory.swift
SOURCES += SynthesizedEventNumberSequence.swift SharedSynthesizedEvents.swift
SOURCES += DelegatedRequestBody.swift AudioRequest.swift
SOURCES += MarkdownHTML.swift
SOURCES += ComputerUseFeaturePreferences.swift
SOURCES += CursorMotionCompletion.swift SelectionCursorPositioning.swift ScrollToVisiblePlan.swift
SOURCES += NativeElementAction.swift AXNativeElementActions.swift
SOURCES += SecondaryCursorPreparation.swift NativeInteractionTargetPolicy.swift

typed-app-body-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-typed-app-body-tests Protocol.swift SocketJSONRPC.swift ComputerUseTelemetryContext.swift AppUsageBody.swift ../test/typed-app-body.swift
	/tmp/cua-typed-app-body-tests ../test/typed-app-body-corpus.json

.PHONY: typed-app-body-test

request-activity-test:
	python3 ../test/request-activity.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: request-activity-test

app-policy-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-app-policy-tests Protocol.swift ComputerUsePolicy.swift Configuration/AcuaConfiguration.swift Apps.swift ScreenLockState.swift AppSessions.swift NativeTargetPolicy.swift RequestRuntime.swift SenderRequestContext.swift ../test/app-policy.swift
	/tmp/cua-app-policy-tests

.PHONY: app-policy-test

ACUA_CONFIGURATION_SOURCES = Configuration/AcuaConfiguration.swift Configuration/AcuaConfigurationLoader.swift ComputerUsePolicy.swift

acua-configuration-test:
	@TOML_DIR="$$($(NATIVE_BUILD) --print-toml-module | tail -n 1)" && \
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-I "$$TOML_DIR" "$$TOML_DIR/libCUAToml.a" -lc++ \
		-o /tmp/cua-acua-configuration-tests $(ACUA_CONFIGURATION_SOURCES) ../test/acua-configuration.swift
	/tmp/cua-acua-configuration-tests

.PHONY: acua-configuration-test

# App approval for MCP clients without elicitation: the service-side decision
# (allow list, then the native dialog) with a fake dialog.
ACUA_APP_APPROVAL_SOURCES = Configuration/AcuaConfiguration.swift Native/acua-app-approval/AcuaAppApproval.swift

acua-app-approval-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-o /tmp/cua-acua-app-approval-tests $(ACUA_APP_APPROVAL_SOURCES) ../test/acua-app-approval.swift
	/tmp/cua-acua-app-approval-tests

.PHONY: acua-app-approval-test

# MCP app approval in the client: channel choice from the initialize
# capabilities and the service dialog's decisions, with fakes for the service.
ACUA_MCP_APPROVAL_SOURCES = ClientMCPAutomationApproval.swift ClientMCPClientCapabilities.swift ClientMCPApprovalPrompt.swift ClientAppApprovalStore.swift \
	ClientMCPAutomationArguments.swift ClientMCPAutomationSpanTelemetry.swift ClientAutomationRequests.swift \
	Native/native-client-nonempty-responses/ClientApplicationRequests.swift \
	Native/native-client-nonempty-responses/ClientIPCRequest.swift Native/native-client-nonempty-responses/AgentTurnEnded.swift

acua-mcp-approval-test:
	@MCP_DIR="$$($(NATIVE_BUILD) --print-mcp-module | tail -n 1 | awk '{print $$NF}')" && \
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-I "$$MCP_DIR" -L "$$MCP_DIR" -lMCP -lLogging -lSystemPackage \
		-o /tmp/cua-acua-mcp-approval-tests $(ACUA_MCP_APPROVAL_SOURCES) ../test/acua-mcp-approval-channel.swift
	/tmp/cua-acua-mcp-approval-tests

.PHONY: acua-mcp-approval-test

# `mcp install` and `mcp uninstall`: server entries, "mcpServers" file edits
# and printed instructions, in a temporary directory.
acua-mcp-install-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-o /tmp/cua-acua-mcp-install-tests ClientMCPInstall.swift ClientMCPApprovalPrompt.swift ../test/acua-mcp-install.swift
	/tmp/cua-acua-mcp-install-tests

.PHONY: acua-mcp-install-test

# Screenshot size budget: encodings tried and the file kept, with a fake writer.
acua-screenshot-budget-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-o /tmp/cua-acua-screenshot-budget-tests Configuration/AcuaConfiguration.swift \
		Native/acua-screenshot-budget/AcuaScreenshotBudget.swift ../test/acua-screenshot-budget.swift
	/tmp/cua-acua-screenshot-budget-tests

.PHONY: acua-screenshot-budget-test

# What get_app_state returns over MCP: base64 image content and app-specific
# instructions once per app per connection, with injected file reads.
ACUA_MCP_OUTPUT_SOURCES = ClientMCPAutomationFormatting.swift ClientAutomationRequests.swift \
	Native/native-client-nonempty-responses/ClientApplicationRequests.swift \
	Native/native-client-nonempty-responses/ClientIPCRequest.swift Native/native-client-nonempty-responses/AgentTurnEnded.swift

acua-mcp-output-test:
	@MCP_DIR="$$($(NATIVE_BUILD) --print-mcp-module | tail -n 1 | awk '{print $$NF}')" && \
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-I "$$MCP_DIR" -L "$$MCP_DIR" -lMCP -lLogging -lSystemPackage \
		-o /tmp/cua-acua-mcp-output-tests $(ACUA_MCP_OUTPUT_SOURCES) ../test/acua-mcp-output.swift
	/tmp/cua-acua-mcp-output-tests

.PHONY: acua-mcp-output-test

# Approval requests to the MCP client: none to a client without elicitation,
# and none waited on past the cancellation of the tool call.
ACUA_MCP_ELICITATION_SOURCES = ClientMCPElicitation.swift ClientMCPInvocationContext.swift ClientMCPTurn.swift \
	ClientAgentProcess.swift ClientMCPEventStream.swift ComputerUseTelemetryContext.swift \
	Native/native-client-nonempty-responses/ClientApplicationRequests.swift \
	Native/native-client-nonempty-responses/ClientIPCRequest.swift Native/native-client-nonempty-responses/AgentTurnEnded.swift

acua-mcp-elicitation-test:
	@MCP_DIR="$$($(NATIVE_BUILD) --print-mcp-module | tail -n 1 | awk '{print $$NF}')" && \
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-I "$$MCP_DIR" -L "$$MCP_DIR" -lMCP -lLogging -lSystemPackage \
		-o /tmp/cua-acua-mcp-elicitation-tests $(ACUA_MCP_ELICITATION_SOURCES) ../test/acua-mcp-elicitation.swift
	/tmp/cua-acua-mcp-elicitation-tests

.PHONY: acua-mcp-elicitation-test

# The service's approval form for MCP clients without elicitation: accepted
# schemas, field order and the elicitation-shaped answer, without a dialog.
acua-approval-form-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-o /tmp/cua-acua-approval-form-tests Native/acua-app-approval/AcuaApprovalForm.swift ../test/acua-approval-form.swift
	/tmp/cua-acua-approval-form-tests

.PHONY: acua-approval-form-test

# The HTTP layer under MCP over streamable HTTP: request parsing, response
# encoding and the path and token gate, without a socket.
acua-mcp-http-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-o /tmp/cua-acua-mcp-http-tests ClientMCPHTTP.swift ../test/acua-mcp-http.swift
	/tmp/cua-acua-mcp-http-tests

.PHONY: acua-mcp-http-test

# The public turn contract: session tracking in the service and turn
# resolution in the MCP client. Pure logic, no service or MCP connection.
ACUA_TURN_CONTRACT_SOURCES = Native/authenticated-preparation-native-owner/ServiceAgentSessionTracker.swift \
	ComputerUseTelemetryContext.swift Native/native-client-nonempty-responses/AgentTurnEnded.swift ClientMCPTurn.swift \
	ClientAgentProcess.swift

acua-turn-contract-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-o /tmp/cua-acua-turn-contract-tests $(ACUA_TURN_CONTRACT_SOURCES) ../test/acua-turn-contract.swift
	/tmp/cua-acua-turn-contract-tests

.PHONY: acua-turn-contract-test

# The agent-process session shared by an agent's stop hook and the MCP helper
# it started, and `turn-ended --agent-process`, with stubbed process tables.
acua-agent-process-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-o /tmp/cua-acua-agent-process-tests ClientAgentProcess.swift Native/native-client-nonempty-responses/AgentTurnEnded.swift \
		../test/acua-agent-process.swift
	/tmp/cua-acua-agent-process-tests

.PHONY: acua-agent-process-test

# `hooks install` and `hooks uninstall`: Claude Code settings.json, Cursor
# hooks.json and Codex config.toml edits, in a temporary directory.
acua-hooks-install-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-o /tmp/cua-acua-hooks-install-tests ClientMCPInstall.swift ClientMCPApprovalPrompt.swift ClientHooksInstall.swift ../test/acua-hooks-install.swift
	/tmp/cua-acua-hooks-install-tests

.PHONY: acua-hooks-install-test

# type_text's text-to-keystroke translation, with a fake keyboard layout.
ACUA_KEYBOARD_TEXT_SOURCES = Native/native-keyboard-actions/ControllerKeyboardEvents.swift \
	Native/native-keyboard-actions/ControllerKeyboardTextTranslation.swift

acua-keyboard-text-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-o /tmp/cua-acua-keyboard-text-tests $(ACUA_KEYBOARD_TEXT_SOURCES) ../test/acua-keyboard-text-translation.swift
	/tmp/cua-acua-keyboard-text-tests

.PHONY: acua-keyboard-text-test

# Choosing the window a mouse event is addressed to, with a fake AX backend.
ACUA_MOUSE_TARGET_SOURCES = Native/controller-native-delivery/ControllerMouseEventTarget.swift AXParentChain.swift

acua-mouse-target-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-o /tmp/cua-acua-mouse-target-tests $(ACUA_MOUSE_TARGET_SOURCES) ../test/acua-mouse-event-target.swift
	/tmp/cua-acua-mouse-target-tests

.PHONY: acua-mouse-target-test

# The app snapshot when the app's window cannot be matched to a WindowServer
# window for a moment, with a fake backend.
ACUA_APP_SNAPSHOT_RETRY_SOURCES = Native/controller-native-operations/ControllerAppSnapshotOperation.swift

acua-app-snapshot-retry-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-o /tmp/cua-acua-app-snapshot-retry-tests $(ACUA_APP_SNAPSHOT_RETRY_SOURCES) ../test/acua-app-snapshot-retry.swift
	/tmp/cua-acua-app-snapshot-retry-tests

.PHONY: acua-app-snapshot-retry-test

# Revealing an offscreen element through its scroll area, with a fake AX tree.
ACUA_SCROLL_REVEAL_SOURCES = Native/controller-native-position/ControllerClickablePoint.swift ScrollToVisiblePlan.swift ClickableGeometry.swift

acua-scroll-reveal-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(DEPLOYMENT_FLAGS) \
		-o /tmp/cua-acua-scroll-reveal-tests $(ACUA_SCROLL_REVEAL_SOURCES) ../test/acua-scroll-reveal.swift
	/tmp/cua-acua-scroll-reveal-tests

.PHONY: acua-scroll-reveal-test

computer-use-policy-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-computer-use-policy-tests ComputerUsePolicy.swift Configuration/AcuaConfiguration.swift ../test/computer-use-policy.swift
	/tmp/cua-computer-use-policy-tests

.PHONY: computer-use-policy-test

mouse-click-events-test:
	python3 ../test/native-drag-events.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-mouse-click-event-tests Protocol.swift SynthesizedEventNumberSequence.swift MouseClickEventFactory.swift ../test/mouse-click-events.swift
	/tmp/cua-mouse-click-event-tests ../test/mouse-click-events-expected.json

.PHONY: mouse-click-events-test

synthesized-events-test:
	python3 ../test/synthesized-events.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: synthesized-events-test

native-scroll-test:
	python3 ../test/native-scroll.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"
	python3 ../test/native-scroll-dispatch.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: native-scroll-test

delegated-request-body-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-delegated-body-tests Protocol.swift SocketJSONRPC.swift ComputerUseTelemetryContext.swift AppUsageBody.swift DelegatedRequestBody.swift AudioRequest.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift AppCaptureProtocol.swift EventStreamProtocol.swift CalendarWire.swift MessagesWire.swift TimelineProtocol.swift ../test/delegated-request-body.swift
	/tmp/cua-delegated-body-tests ../test/delegated-request-body-corpus.json /tmp/cua-delegated-body-result.json ../test/delegated-request-body-expected.json

socket-response-body-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-socket-response-body-tests Protocol.swift SocketJSONRPC.swift ComputerUseTelemetryContext.swift AppUsageBody.swift DelegatedRequestBody.swift AudioRequest.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift AppCaptureProtocol.swift EventStreamProtocol.swift CalendarWire.swift MessagesWire.swift TimelineProtocol.swift SocketResponseBody.swift ../test/socket-response-body.swift
	/tmp/cua-socket-response-body-tests ../test/socket-response-body-corpus.json

CUA_CODEC_BOUNDARY_HARNESS ?= /tmp/cua-codec-boundary-harness/AexComputerUseService
codec-boundary-harness-build:
	python3 ../test/build-native-automation-harness.py --output "$(CUA_CODEC_BOUNDARY_HARNESS)" --swiftflags="$(SWIFTFLAGS)" --codec-boundary-probe

.PHONY: delegated-request-body-test codec-boundary-harness-build
BIN = AexComputerUseService
# BIN stays the raw development executable used by component tests.
BUNDLE_EXECUTABLE = AexComputerUseService
APP_BUNDLE = $(BUNDLE_EXECUTABLE).app
SERVICE_DIR ?= $(HOME)/Library/Application Support/ACUA

build:
	$(NATIVE_BUILD)

component-fixture-build:
	$(SWIFTC) $(SWIFTFLAGS) $(DEPLOYMENT_FLAGS) $(LEGACY_FIXTURE_FLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker CalendarPermissionInfo.plist -o /tmp/cua-component-fixture-base $(SOURCES)

.PHONY: component-fixture-build

bundle: build
	$(NATIVE_BUILD) --bundle "$(APP_BUNDLE)"
	python3 verify_bundle_payload.py $(BIN) "$(APP_BUNDLE)/Contents/MacOS/$(BUNDLE_EXECUTABLE)"
	python3 verify_deployment.py $(BIN) --bundle "$(APP_BUNDLE)" --target "$(SWIFT_TARGET)" --minimum "$(MACOSX_DEPLOYMENT_TARGET)"

.PHONY: bundle

cursor-artwork-test:
	$(SWIFTC) $(SWIFTFLAGS) $(DEPLOYMENT_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-cursor-artwork-tests CursorArtwork.swift ../test/cursor-artwork.swift
	/tmp/cua-cursor-artwork-tests /tmp/cua-cursor-artwork-result

.PHONY: cursor-artwork-test

deployment-target-test: bundle
	$(MAKE) deployment-target-check

deployment-target-check:
	python3 ../test/deployment-target.py --binary $(BIN) --bundle "$(APP_BUNDLE)" --target "$(SWIFT_TARGET)" --minimum "$(MACOSX_DEPLOYMENT_TARGET)"

.PHONY: deployment-target-test deployment-target-check

socket-io-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-socket-io-tests SocketIO.swift ResponseDelivery.swift ../test/socket-io.swift
	/tmp/cua-socket-io-tests
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-socket-transport-tests SocketIO.swift ../test/socket-transport.swift
	/tmp/cua-socket-transport-tests
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-socket-retry-tests SocketIO.swift ../test/socket-retry.swift
	/tmp/cua-socket-retry-tests
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-socket-resource-tests SocketIO.swift ../test/socket-resource-limits.swift
	python3 ../test/socket-resource-limits.py --helper /tmp/cua-socket-resource-tests
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-socket-startup-tests SocketIO.swift ../test/socket-startup.swift
	/tmp/cua-socket-startup-tests

sender-authorization-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-sender-authorization-tests SenderAuthorization.swift AppleEventAuthorization.swift SenderRequestContext.swift ../test/sender-authorization.swift
	/tmp/cua-sender-authorization-tests

sender-request-context-test:
	python3 ../test/sender-request-context.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: sender-request-context-test

sender-peer-native-build:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-sender-peer-native SenderAuthorization.swift AppleEventAuthorization.swift SenderRequestContext.swift ../test/sender-peer-native.swift

event-stream-storage-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-storage-tests EventStreamProtocol.swift EventStreamJSONLWriter.swift ../test/event-stream-storage.swift
	/tmp/cua-event-stream-storage-tests
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-service-group-configuration EventStreamStorageConfiguration.swift ../test/service-group-configuration.swift
	/tmp/cua-service-group-configuration

event-stream-rendering-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-rendering-tests EventStreamProtocol.swift EventStreamJSONLWriter.swift EventStreamPresentation.swift EventStreamTreeRendering.swift ../test/event-stream-rendering.swift
	/tmp/cua-event-stream-rendering-tests

.PHONY: event-stream-rendering-test

event-stream-children-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-children-tests EventStreamChildren.swift ../test/event-stream-children.swift
	/tmp/cua-event-stream-children-tests

.PHONY: event-stream-children-test

event-stream-children-native-build:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-children-native EventStreamProtocol.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift EventStreamChildren.swift EventStreamNativeChildren.swift ../test/event-stream-children-native.swift

.PHONY: event-stream-children-native-build

event-stream-snapshots-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-snapshots-tests EventStreamProtocol.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift EventStreamElementSnapshots.swift EventStreamNativeSnapshots.swift EventStreamHierarchySPI.swift EventStreamHierarchyCapture.swift EventStreamTreeTransaction.swift ../test/event-stream-snapshots.swift
	/tmp/cua-event-stream-snapshots-tests

.PHONY: event-stream-snapshots-test

event-stream-snapshots-native-build:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-snapshots-native $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-snapshots-native.swift

.PHONY: event-stream-snapshots-native-build

.PHONY: event-stream-storage-test

event-stream-capture-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-capture-tests EventStreamProtocol.swift EventStreamCaptureCoordinator.swift EventStreamInputPolicy.swift EventStreamInputTap.swift ../test/event-stream-capture.swift
	/tmp/cua-event-stream-capture-tests

.PHONY: event-stream-capture-test

event-stream-policy-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-policy-tests EventStreamProtocol.swift EventStreamApplicationResolver.swift EventStreamURLPolicy.swift ../test/event-stream-policy.swift
	/tmp/cua-event-stream-policy-tests

event-stream-ax-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-ax-tests EventStreamProtocol.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift ../test/event-stream-ax.swift
	/tmp/cua-event-stream-ax-tests

.PHONY: event-stream-policy-test event-stream-ax-test

event-stream-ax-native-build:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-ax-fixture ../test/EventStreamAXFixture.swift
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-ax-native EventStreamProtocol.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift ../test/event-stream-ax-native.swift

.PHONY: event-stream-ax-native-build

event-stream-records-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-record-tests EventStreamProtocol.swift EventStreamApplicationResolver.swift EventStreamURLPolicy.swift EventStreamJSONLWriter.swift EventStreamRecordProcessor.swift ../test/event-stream-records.swift
	/tmp/cua-event-stream-record-tests

.PHONY: event-stream-records-test

event-stream-text-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-text-tests EventStreamProtocol.swift EventStreamTextInputRecorder.swift EventStreamApplicationResolver.swift EventStreamURLPolicy.swift EventStreamJSONLWriter.swift EventStreamRecordProcessor.swift ../test/event-stream-text.swift
	/tmp/cua-event-stream-text-tests

.PHONY: event-stream-text-test

event-stream-interaction-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-interaction-tests EventStreamProtocol.swift EventStreamTextInputRecorder.swift EventStreamInputPolicy.swift EventStreamInteractionPolicy.swift EventStreamInputRecordBuilder.swift ../test/event-stream-interactions.swift
	/tmp/cua-event-stream-interaction-tests

.PHONY: event-stream-interaction-test

event-stream-context-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-context-tests EventStreamProtocol.swift EventStreamTextInputRecorder.swift EventStreamInteractionPolicy.swift EventStreamAXContent.swift AXParentChain.swift EventStreamContextResolver.swift ../test/event-stream-context.swift
	/tmp/cua-event-stream-context-tests

event-stream-context-native-build:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-context-native Protocol.swift AccessibilityWindowSPI.swift EventStreamProtocol.swift EventStreamTextInputRecorder.swift EventStreamInputPolicy.swift EventStreamInteractionPolicy.swift EventStreamInputRecordBuilder.swift EventStreamApplicationResolver.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift AXParentChain.swift EventStreamContextResolver.swift WindowDescription.swift EventStreamNativeContext.swift EventStreamFrontmostTracker.swift EventStreamFrontmostObservers.swift EventStreamRecordFactory.swift EventStreamAXCapture.swift ../test/event-stream-context-native.swift

.PHONY: event-stream-context-test event-stream-context-native-build

event-stream-frontmost-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-frontmost-tests EventStreamFrontmostTracker.swift EventStreamFrontmostObservers.swift ../test/event-stream-frontmost.swift
	/tmp/cua-event-stream-frontmost-tests

.PHONY: event-stream-frontmost-test

event-stream-text-native-build:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-text-fixture ../test/InputFixture.swift
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-text-native Protocol.swift AccessibilityWindowSPI.swift EventStreamProtocol.swift EventStreamTextInputRecorder.swift EventStreamInputPolicy.swift EventStreamInputTap.swift EventStreamInteractionPolicy.swift EventStreamInputRecordBuilder.swift EventStreamApplicationResolver.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift AXParentChain.swift EventStreamContextResolver.swift WindowDescription.swift EventStreamNativeContext.swift EventStreamFrontmostTracker.swift EventStreamFrontmostObservers.swift EventStreamRecordFactory.swift EventStreamAXCapture.swift EventStreamJSONLWriter.swift EventStreamRecordProcessor.swift EventStreamURLPolicy.swift ../test/event-stream-text-native.swift

.PHONY: event-stream-text-native-build

event-stream-factory-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-factory-tests EventStreamProtocol.swift EventStreamTextInputRecorder.swift EventStreamInputPolicy.swift EventStreamInteractionPolicy.swift EventStreamInputRecordBuilder.swift EventStreamRecordFactory.swift EventStreamAXCapture.swift EventStreamApplicationResolver.swift EventStreamURLPolicy.swift EventStreamJSONLWriter.swift EventStreamRecordProcessor.swift EventStreamPresentation.swift EventStreamTreeRendering.swift ../test/event-stream-factory.swift
	/tmp/cua-event-stream-factory-tests

.PHONY: event-stream-factory-test

synthetic-focus-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-synthetic-focus-tests Protocol.swift ClickableGeometry.swift UserInteraction.swift SyntheticFocusEvents.swift FocusRestorationPolicy.swift ../test/synthetic-focus.swift
	/tmp/cua-synthetic-focus-tests

synthetic-focus-probe-build:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-synthetic-focus-probe Protocol.swift ClickableGeometry.swift UserInteraction.swift SyntheticFocusEvents.swift KeyboardFocusSPI.swift ../test/synthetic-focus-probe.swift

system-keyboard-focus-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-system-keyboard-focus-tests SystemKeyboardFocusState.swift ../test/system-keyboard-focus.swift
	/tmp/cua-system-keyboard-focus-tests

hosted-focus-repair-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-hosted-focus-repair-tests SystemKeyboardFocusState.swift HostedFocusRepair.swift ../test/hosted-focus-repair.swift
	/tmp/cua-hosted-focus-repair-tests

hosted-focus-repair-native-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-hosted-focus-repair-packets Protocol.swift ClickableGeometry.swift UserInteraction.swift SyntheticFocusEvents.swift ../test/hosted-focus-repair-packets.swift
	/tmp/cua-hosted-focus-repair-packets

.PHONY: hosted-focus-repair-test hosted-focus-repair-native-test

focus-restoration-native-build:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-focus-restoration-native $(filter-out main.swift,$(SOURCES)) ../test/focus-restoration-native.swift

selftest: build
	./$(BIN) --selftest

geometry-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-geometry-tests Protocol.swift ScreenshotGeometry.swift CaptureLayout.swift ../test/geometry.swift
	/tmp/cua-geometry-tests
	python3 ../test/native-coordinate-state.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

capture-layout-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-capture-layout-tests Protocol.swift ScreenshotGeometry.swift CaptureLayout.swift ../test/capture-layout.swift
	/tmp/cua-capture-layout-tests


action-cursor-policy-test:
	python3 ../test/action-cursor-policy.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: action-cursor-policy-test

native-click-policy-test: native-click-web-test native-mouse-click-test native-click-focus-test
	python3 ../test/native-click-policy.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: native-click-policy-test

secondary-action-test: secondary-preparation-test
	python3 ../test/secondary-action-dispatch.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-native-element-action-tests Protocol.swift NativeElementAction.swift AXNativeElementActions.swift ../test/native-element-actions.swift
	/tmp/cua-native-element-action-tests ../test/native-element-action-expected.json /tmp/cua-native-element-action-result.json

.PHONY: secondary-action-test

secondary-preparation-test:
	python3 ../test/secondary-preparation.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: secondary-preparation-test

cursor-interaction-timing-test:
	python3 ../test/cursor-interaction-timing.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: cursor-interaction-timing-test

selection-cursor-test: cursor-interaction-timing-test
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-selection-cursor-tests ClickableGeometry.swift ScrollToVisiblePlan.swift SelectionCursorPositioning.swift CursorMotionCompletion.swift ../test/selection-cursor-position.swift
	/tmp/cua-selection-cursor-tests /tmp/cua-selection-cursor-result.json ../test/scroll-action-membership-expected.json
	python3 ../test/cursor-motion-driver.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"
	python3 ../test/selection-dispatch.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: selection-cursor-test

cursor-capture-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-cursor-capture-tests Protocol.swift ComputerUseFeaturePreferences.swift CursorMotionCompletion.swift NativeMouseClick.swift CursorOverlay.swift CursorArtwork.swift CursorCapture.swift ../test/cursor-capture.swift
	/tmp/cua-cursor-capture-tests

window-target-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-window-target-tests Protocol.swift ScreenshotGeometry.swift CaptureLayout.swift MouseTargeting.swift ../test/window-targeting.swift
	/tmp/cua-window-target-tests

window-target-native-build:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-window-target-native-tests $(filter-out main.swift,$(SOURCES)) ../test/window-target-native.swift

window-target-native-test: window-target-native-build
	/tmp/cua-window-target-native-tests

input-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-input-tests Protocol.swift ComputerUsePolicy.swift Configuration/AcuaConfiguration.swift Apps.swift ScreenLockState.swift AppSessions.swift NativeTargetPolicy.swift TextSelection.swift KeyChord.swift RequestRuntime.swift SenderRequestContext.swift ../test/input.swift
	/tmp/cua-input-tests

frame-encoding-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-frame-encoding-tests Protocol.swift ../test/frame-encoding.swift
	/tmp/cua-frame-encoding-tests

.PHONY: frame-encoding-test

socket-jsonrpc-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-socket-jsonrpc-tests Protocol.swift SocketJSONRPC.swift ../test/socket-jsonrpc.swift
	/tmp/cua-socket-jsonrpc-tests ../test/socket-jsonrpc-corpus.json

.PHONY: socket-jsonrpc-test

tree-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-tree-tests Protocol.swift TreeRevision.swift ../test/tree-revision.swift
	/tmp/cua-tree-tests

clickable-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-clickable-tests ClickableGeometry.swift ../test/clickable.swift
	/tmp/cua-clickable-tests

session-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-session-tests Protocol.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift ../test/sessions.swift
	/tmp/cua-session-tests

pending-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-pending-tests Protocol.swift PendingResult.swift ../test/pending.swift
	/tmp/cua-pending-tests

capture-stream-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-capture-stream-tests Protocol.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift AppCaptureProtocol.swift AppCaptureStore.swift ../test/capture-stream.swift
	/tmp/cua-capture-stream-tests

capture-transition-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-capture-transition-tests Protocol.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift AppCaptureProtocol.swift CaptureTransitionGeometry.swift ../test/capture-transition.swift
	/tmp/cua-capture-transition-tests

capture-coordinator-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-capture-coordinator-tests Protocol.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift AppCaptureProtocol.swift AppCaptureStore.swift ResponseDelivery.swift SystemSettings.swift SystemSettingsTransitionGeometry.swift SystemSettingsTransitionAppearance.swift SystemSettingsTransitionReplicantView.swift SystemSettingsScalarSpring.swift SystemSettingsSpringAnimation.swift SystemSettingsDisplayLinkDriver.swift SystemSettingsSpringDriverBinding.swift SettingsAccessoryCapture.swift SettingsTransitionController.swift SystemSettingsTransitionAnimationBinding.swift AppCaptureCoordinator.swift AppshotPermissionTransition.swift ../test/capture-coordinator.swift
	/tmp/cua-capture-coordinator-tests

system-settings-test:
	python3 ../test/system-settings.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: system-settings-test

system-settings-transition-test:
	python3 ../test/system-settings-transition.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: system-settings-transition-test

system-settings-spring-test:
	python3 ../test/system-settings-spring.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: system-settings-spring-test

system-settings-animation-test:
	python3 ../test/system-settings-animation.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: system-settings-animation-test

audio-lifecycle-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-audio-lifecycle-tests Protocol.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift PendingResult.swift AudioRequest.swift AudioCaptureBridge.swift Audio.swift ../test/audio-lifecycle.swift ../test/audio-capture-bridge.swift
	/tmp/cua-audio-lifecycle-tests

audio-reentrant-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-audio-reentrant-tests Protocol.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift PendingResult.swift AudioRequest.swift AudioCaptureBridge.swift Audio.swift ../test/audio-reentrant.swift
	/tmp/cua-audio-reentrant-tests /tmp/cua-audio-reentrant-result.json ../test/audio-reentrant-expected.json

.PHONY: audio-reentrant-test

app-usage-catalog-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-app-usage-catalog-tests Protocol.swift AppUsageCatalog.swift ../test/app-usage-catalog.swift
	/tmp/cua-app-usage-catalog-tests

intervention-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-intervention-tests Protocol.swift AppSessions.swift UserInteraction.swift ../test/intervention.swift
	/tmp/cua-intervention-tests

# Shipped signing choices: hardened runtime, timestamp, entitlements, version
bundle-signing-test:
	python3 ../test/bundle-signing.py

.PHONY: bundle-signing-test

install: bundle
	python3 install_native.py --distribution "$(NATIVE_BUILD_DIR)/dist" --destination "$(SERVICE_DIR)"

clean:
	rm -f $(BIN)

.PHONY: build selftest socket-io-test sender-authorization-test sender-peer-native-build synthetic-focus-test system-keyboard-focus-test synthetic-focus-probe-build focus-restoration-native-build focus-preventer-native-build geometry-test capture-layout-test cursor-capture-test window-target-test window-target-native-build window-target-native-test input-test tree-test clickable-test session-test pending-test capture-stream-test capture-coordinator-test capture-transition-test intervention-test install clean

focus-preventer-native-build:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-focus-preventer-native $(filter-out main.swift,$(SOURCES)) ../test/focus-preventer-native.swift

event-stream-hierarchy-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-hierarchy-tests EventStreamProtocol.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift EventStreamElementSnapshots.swift EventStreamNativeSnapshots.swift EventStreamHierarchySPI.swift EventStreamHierarchyCapture.swift EventStreamTreeTransaction.swift EventStreamChildren.swift EventStreamNativeChildren.swift ../test/event-stream-hierarchy.swift
	/tmp/cua-event-stream-hierarchy-tests

.PHONY: event-stream-hierarchy-test

SOURCES += EventStreamTransformedValue.swift EventStreamNativeValue.swift

event-stream-value-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-value-tests EventStreamPartialValue.swift EventStreamTransformedValue.swift EventStreamPresentation.swift ../test/event-stream-value.swift
	/tmp/cua-event-stream-value-tests

.PHONY: event-stream-value-test

SOURCES += EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamNativeNode.swift

event-stream-node-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-node-tests EventStreamPartialValue.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift ../test/event-stream-node.swift
	/tmp/cua-event-stream-node-tests

.PHONY: event-stream-node-test

SOURCES += EventStreamTreeCollection.swift EventStreamNativeTreeCollection.swift
SOURCES += EventStreamTreeTransformation.swift EventStreamNativeTreeTransformation.swift
SOURCES += EventStreamTransformationContextFactory.swift EventStreamNativeTransformationContext.swift
EVENT_STREAM_TREE_TRANSFORMATION_SOURCES = EventStreamProtocol.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift EventStreamElementSnapshots.swift EventStreamNativeSnapshots.swift EventStreamHierarchySPI.swift EventStreamHierarchyCapture.swift EventStreamTreeTransaction.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamChildren.swift EventStreamTreeCollection.swift EventStreamTreePruning.swift EventStreamSharedTreeTransform.swift EventStreamTitleAssociation.swift EventStreamNativeTitleAssociation.swift EventStreamURLShortener.swift EventStreamMarkdownLink.swift EventStreamLinkTransformation.swift EventStreamTextSiblingTransformation.swift EventStreamMacTreeTransform.swift EventStreamNativeMacTransformation.swift EventStreamAttributedTextAcquisition.swift EventStreamNativeAttributedText.swift EventStreamAttributedMarkdown.swift EventStreamNativeAttributedMarkdown.swift EventStreamNativeValue.swift EventStreamNativeNode.swift EventStreamNativeChildren.swift EventStreamNativeTreeCollection.swift EventStreamTreeTransformation.swift EventStreamNativeTreeTransformation.swift EventStreamTransformationContextFactory.swift EventStreamNativeTransformationContext.swift

event-stream-tree-collection-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-tree-collection-tests EventStreamProtocol.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift EventStreamElementSnapshots.swift EventStreamNativeSnapshots.swift EventStreamHierarchySPI.swift EventStreamHierarchyCapture.swift EventStreamTreeTransaction.swift EventStreamTransformedValue.swift EventStreamNativeValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamNativeNode.swift EventStreamChildren.swift EventStreamNativeChildren.swift EventStreamTreeCollection.swift EventStreamNativeTreeCollection.swift ../test/event-stream-tree-collection.swift
	/tmp/cua-event-stream-tree-collection-tests

.PHONY: event-stream-tree-collection-test

SOURCES += EventStreamTreePruning.swift

event-stream-pruning-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-pruning-tests EventStreamPartialValue.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamChildren.swift EventStreamTreeCollection.swift EventStreamTreePruning.swift ../test/event-stream-pruning.swift
	/tmp/cua-event-stream-pruning-tests

.PHONY: event-stream-pruning-test

SOURCES += EventStreamSharedTreeTransform.swift
SOURCES += EventStreamTitleAssociation.swift EventStreamNativeTitleAssociation.swift
SOURCES += EventStreamMacTreeTransform.swift EventStreamNativeMacTransformation.swift
SOURCES += EventStreamAttributedTextAcquisition.swift EventStreamNativeAttributedText.swift
SOURCES += EventStreamAttributedMarkdown.swift EventStreamNativeAttributedMarkdown.swift

event-stream-attributed-native-build:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-attributed-native $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-attributed-native.swift

.PHONY: event-stream-attributed-native-build

event-stream-attributed-markdown-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-attributed-markdown-tests EventStreamProtocol.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift EventStreamElementSnapshots.swift EventStreamNativeSnapshots.swift EventStreamHierarchySPI.swift EventStreamHierarchyCapture.swift EventStreamTreeTransaction.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamChildren.swift EventStreamTreeCollection.swift EventStreamTreePruning.swift EventStreamSharedTreeTransform.swift EventStreamTitleAssociation.swift EventStreamNativeTitleAssociation.swift EventStreamURLShortener.swift EventStreamMarkdownLink.swift EventStreamLinkTransformation.swift EventStreamTextSiblingTransformation.swift EventStreamMacTreeTransform.swift EventStreamNativeMacTransformation.swift EventStreamAttributedTextAcquisition.swift EventStreamNativeAttributedText.swift EventStreamAttributedMarkdown.swift EventStreamNativeAttributedMarkdown.swift ../test/event-stream-attributed-markdown.swift
	/tmp/cua-event-stream-attributed-markdown-tests

.PHONY: event-stream-attributed-markdown-test

event-stream-attributed-acquisition-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-attributed-acquisition-tests EventStreamProtocol.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift EventStreamElementSnapshots.swift EventStreamNativeSnapshots.swift EventStreamHierarchySPI.swift EventStreamHierarchyCapture.swift EventStreamTreeTransaction.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamChildren.swift EventStreamTreeCollection.swift EventStreamTreePruning.swift EventStreamSharedTreeTransform.swift EventStreamTitleAssociation.swift EventStreamNativeTitleAssociation.swift EventStreamURLShortener.swift EventStreamMarkdownLink.swift EventStreamLinkTransformation.swift EventStreamTextSiblingTransformation.swift EventStreamMacTreeTransform.swift EventStreamNativeMacTransformation.swift EventStreamAttributedTextAcquisition.swift EventStreamNativeAttributedText.swift ../test/event-stream-attributed-acquisition.swift
	/tmp/cua-event-stream-attributed-acquisition-tests

.PHONY: event-stream-attributed-acquisition-test

event-stream-mac-transform-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-mac-transform-tests EventStreamProtocol.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift EventStreamElementSnapshots.swift EventStreamNativeSnapshots.swift EventStreamHierarchySPI.swift EventStreamHierarchyCapture.swift EventStreamTreeTransaction.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamChildren.swift EventStreamTreeCollection.swift EventStreamTreePruning.swift EventStreamSharedTreeTransform.swift EventStreamTitleAssociation.swift EventStreamNativeTitleAssociation.swift EventStreamURLShortener.swift EventStreamMarkdownLink.swift EventStreamLinkTransformation.swift EventStreamTextSiblingTransformation.swift EventStreamMacTreeTransform.swift EventStreamNativeMacTransformation.swift ../test/event-stream-mac-transform.swift
	/tmp/cua-event-stream-mac-transform-tests

.PHONY: event-stream-mac-transform-test

event-stream-title-association-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-title-association-tests EventStreamProtocol.swift EventStreamAXContent.swift EventStreamAXContext.swift EventStreamPartialValue.swift EventStreamElementSnapshots.swift EventStreamNativeSnapshots.swift EventStreamHierarchySPI.swift EventStreamHierarchyCapture.swift EventStreamTreeTransaction.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamChildren.swift EventStreamTreeCollection.swift EventStreamTreePruning.swift EventStreamSharedTreeTransform.swift EventStreamTitleAssociation.swift EventStreamNativeTitleAssociation.swift ../test/event-stream-title-association.swift
	/tmp/cua-event-stream-title-association-tests

.PHONY: event-stream-title-association-test

event-stream-shared-transform-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-shared-transform-tests EventStreamPartialValue.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamChildren.swift EventStreamTreeCollection.swift EventStreamTreePruning.swift EventStreamSharedTreeTransform.swift ../test/event-stream-shared-transform.swift
	/tmp/cua-event-stream-shared-transform-tests

.PHONY: event-stream-shared-transform-test

event-stream-selectable-transform-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-selectable-transform-tests EventStreamPartialValue.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamChildren.swift EventStreamTreeCollection.swift EventStreamTreePruning.swift EventStreamSharedTreeTransform.swift ../test/event-stream-selectable-transform.swift
	/tmp/cua-event-stream-selectable-transform-tests

.PHONY: event-stream-selectable-transform-test

event-stream-repetitive-text-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-repetitive-text-tests EventStreamPartialValue.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamChildren.swift EventStreamTreeCollection.swift EventStreamTreePruning.swift EventStreamSharedTreeTransform.swift ../test/event-stream-repetitive-text.swift
	/tmp/cua-event-stream-repetitive-text-tests

.PHONY: event-stream-repetitive-text-test

event-stream-transformed-string-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-transformed-string-tests EventStreamPartialValue.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift ../test/event-stream-transformed-string.swift
	/tmp/cua-event-stream-transformed-string-tests

.PHONY: event-stream-transformed-string-test

SOURCES += EventStreamURLShortener.swift EventStreamMarkdownLink.swift EventStreamLinkTransformation.swift

event-stream-url-shortener-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-url-shortener-tests EventStreamURLShortener.swift ../test/event-stream-url-shortener.swift
	/tmp/cua-event-stream-url-shortener-tests

event-stream-markdown-link-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-markdown-link-tests EventStreamTransformedString.swift EventStreamURLShortener.swift EventStreamMarkdownLink.swift ../test/event-stream-markdown-link.swift
	/tmp/cua-event-stream-markdown-link-tests

event-stream-link-transform-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-link-transform-tests EventStreamPartialValue.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamChildren.swift EventStreamTreeCollection.swift EventStreamTreePruning.swift EventStreamSharedTreeTransform.swift EventStreamURLShortener.swift EventStreamMarkdownLink.swift EventStreamLinkTransformation.swift ../test/event-stream-link-transform.swift
	/tmp/cua-event-stream-link-transform-tests

.PHONY: event-stream-url-shortener-test event-stream-markdown-link-test event-stream-link-transform-test

SOURCES += EventStreamTextSiblingTransformation.swift

event-stream-text-siblings-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-text-siblings-tests EventStreamPartialValue.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamChildren.swift EventStreamTreeCollection.swift EventStreamTreePruning.swift EventStreamSharedTreeTransform.swift EventStreamURLShortener.swift EventStreamMarkdownLink.swift EventStreamLinkTransformation.swift EventStreamTextSiblingTransformation.swift ../test/event-stream-text-siblings.swift
	/tmp/cua-event-stream-text-siblings-tests

.PHONY: event-stream-text-siblings-test

event-stream-tree-transformation-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-tree-transformation-tests $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-tree-transformation.swift
	/tmp/cua-event-stream-tree-transformation-tests

.PHONY: event-stream-tree-transformation-test

event-stream-transformation-context-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-transformation-context-tests $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-transformation-context.swift
	/tmp/cua-event-stream-transformation-context-tests

.PHONY: event-stream-transformation-context-test

SOURCES += EventStreamNativeNodeRendering.swift
EVENT_STREAM_TREE_TRANSFORMATION_SOURCES += EventStreamNativeNodeRendering.swift

event-stream-native-renderer-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-native-renderer-tests $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-native-renderer.swift
	/tmp/cua-event-stream-native-renderer-tests

.PHONY: event-stream-native-renderer-test

SOURCES += EventStreamTreeFocus.swift EventStreamNativeTreeFocus.swift EventStreamTreeURLTrimming.swift
EVENT_STREAM_TREE_TRANSFORMATION_SOURCES += EventStreamTreeFocus.swift EventStreamNativeTreeFocus.swift EventStreamTreeURLTrimming.swift

event-stream-tree-focus-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-tree-focus-tests $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-tree-focus.swift
	/tmp/cua-event-stream-tree-focus-tests

event-stream-tree-url-trimming-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-tree-url-trimming-tests $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-tree-url-trimming.swift
	/tmp/cua-event-stream-tree-url-trimming-tests

.PHONY: event-stream-tree-focus-test event-stream-tree-url-trimming-test

event-stream-tree-focus-native-build:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-tree-focus-native $(filter-out main.swift,$(SOURCES)) ../test/event-stream-tree-focus-native.swift

.PHONY: event-stream-tree-focus-native-build

SOURCES += EventStreamRenderForest.swift EventStreamNativeRenderForest.swift
EVENT_STREAM_TREE_TRANSFORMATION_SOURCES += EventStreamTreeRendering.swift EventStreamRenderForest.swift EventStreamNativeRenderForest.swift

event-stream-render-forest-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-render-forest-tests $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-render-forest.swift
	/tmp/cua-event-stream-render-forest-tests

.PHONY: event-stream-render-forest-test

SOURCES += EventStreamRenderIDs.swift
EVENT_STREAM_TREE_TRANSFORMATION_SOURCES += EventStreamRenderIDs.swift

event-stream-render-ids-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-render-id-tests $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-render-ids.swift
	/tmp/cua-event-stream-render-id-tests

.PHONY: event-stream-render-ids-test

SOURCES += EventStreamRenderDifference.swift
EVENT_STREAM_TREE_TRANSFORMATION_SOURCES += EventStreamRenderDifference.swift

event-stream-render-difference-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-render-difference-tests $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-render-difference.swift
	/tmp/cua-event-stream-render-difference-tests

.PHONY: event-stream-render-difference-test

SOURCES += EventStreamTreeRevision.swift EventStreamRenderSnapshot.swift EventStreamNativeTreeRevision.swift
EVENT_STREAM_TREE_TRANSFORMATION_SOURCES += EventStreamTreeRevision.swift EventStreamRenderSnapshot.swift EventStreamNativeTreeRevision.swift

event-stream-tree-revision-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-tree-revision-tests $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-tree-revision.swift
	/tmp/cua-event-stream-tree-revision-tests

.PHONY: event-stream-tree-revision-test

SOURCES += EventStreamRevisionDifferenceLines.swift
EVENT_STREAM_TREE_TRANSFORMATION_SOURCES += EventStreamRevisionDifferenceLines.swift

event-stream-revision-difference-lines-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-revision-difference-lines-tests $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-revision-difference-lines.swift
	/tmp/cua-event-stream-revision-difference-lines-tests

.PHONY: event-stream-revision-difference-lines-test

SOURCES += EventStreamScreenshotContextPolicy.swift EventStreamSelectionDescription.swift
SOURCES += EventStreamNativeSelectionCapture.swift
EVENT_STREAM_TREE_TRANSFORMATION_SOURCES += EventStreamScreenshotContextPolicy.swift EventStreamSelectionDescription.swift

event-stream-capture-context-policy-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-capture-context-policy-tests $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-capture-context-policy.swift
	/tmp/cua-event-stream-capture-context-policy-tests

.PHONY: event-stream-capture-context-policy-test

SOURCES += EventStreamCaptureTransformation.swift
EVENT_STREAM_TREE_TRANSFORMATION_SOURCES += EventStreamCaptureTransformation.swift

event-stream-capture-transformation-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-capture-transformation-tests $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-capture-transformation.swift
	/tmp/cua-event-stream-capture-transformation-tests

.PHONY: event-stream-capture-transformation-test

SOURCES += EventStreamCaptureCore.swift
EVENT_STREAM_TREE_TRANSFORMATION_SOURCES += EventStreamCaptureCore.swift

event-stream-capture-core-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-capture-core-tests $(EVENT_STREAM_TREE_TRANSFORMATION_SOURCES) ../test/event-stream-capture-core.swift
	/tmp/cua-event-stream-capture-core-tests

.PHONY: event-stream-capture-core-test

SOURCES += EventStreamTreeInvalidationMonitor.swift

event-stream-invalidation-monitor-test:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-invalidation-monitor-tests $(filter-out main.swift,$(SOURCES)) ../test/event-stream-invalidation-monitor.swift
	/tmp/cua-event-stream-invalidation-monitor-tests

.PHONY: event-stream-invalidation-monitor-test

event-stream-invalidation-monitor-native-build:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-invalidation-monitor-native $(filter-out main.swift,$(SOURCES)) ../test/event-stream-invalidation-monitor-native.swift

.PHONY: event-stream-invalidation-monitor-native-build

SOURCES += EventStreamSelectionExtractor.swift

event-stream-selection-extractor-test:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-selection-extractor-tests $(filter-out main.swift,$(SOURCES)) ../test/event-stream-selection-extractor.swift
	/tmp/cua-event-stream-selection-extractor-tests

.PHONY: event-stream-selection-extractor-test

SOURCES += EventStreamSelectionMetadata.swift EventStreamNativeRecorderCapture.swift

event-stream-recorder-metadata-test:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-recorder-metadata-tests $(filter-out main.swift,$(SOURCES)) ../test/event-stream-selection-metadata.swift
	/tmp/cua-event-stream-recorder-metadata-tests

.PHONY: event-stream-recorder-metadata-test

SOURCES += EventStreamApplicationCaptureController.swift EventStreamRecorderAXObservationPolicy.swift EventStreamAXNotificationQueue.swift EventStreamSelectionRecordBuilder.swift

event-stream-application-controller-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-application-controller-test EventStreamProtocol.swift EventStreamTextInputRecorder.swift EventStreamApplicationCaptureController.swift ../test/event-stream-application-controller.swift
	/tmp/cua-event-stream-application-controller-test

event-stream-running-application-metadata-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-running-application-metadata-test EventStreamProtocol.swift EventStreamApplicationResolver.swift ../test/event-stream-running-application-metadata.swift
	/tmp/cua-event-stream-running-application-metadata-test

event-stream-recorder-observation-policy-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-recorder-observation-policy-test EventStreamRecorderAXObservationPolicy.swift ../test/event-stream-recorder-observation-policy.swift
	/tmp/cua-event-stream-recorder-observation-policy-test

event-stream-notification-queue-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-notification-queue-test EventStreamProtocol.swift EventStreamRecorderAXObservationPolicy.swift EventStreamAXNotificationQueue.swift ../test/event-stream-notification-queue.swift
	/tmp/cua-event-stream-notification-queue-test

event-stream-selection-record-builder-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-selection-record-builder-test EventStreamProtocol.swift EventStreamTextInputRecorder.swift EventStreamRecorderAXObservationPolicy.swift EventStreamAXNotificationQueue.swift EventStreamSelectionRecordBuilder.swift ../test/event-stream-selection-record-builder.swift
	/tmp/cua-event-stream-selection-record-builder-test

event-stream-observer-payload-test:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-observer-payload-test $(filter-out main.swift,$(SOURCES)) ../test/event-stream-observer-payload.swift
	/tmp/cua-event-stream-observer-payload-test

.PHONY: event-stream-application-controller-test event-stream-running-application-metadata-test event-stream-recorder-observation-policy-test event-stream-notification-queue-test event-stream-selection-record-builder-test event-stream-observer-payload-test

SOURCES += EventStreamNativeSelectionRecordBackend.swift

event-stream-native-selection-records-test:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-native-selection-records-tests $(filter-out main.swift,$(SOURCES)) ../test/event-stream-native-selection-records.swift
	/tmp/cua-event-stream-native-selection-records-tests

event-stream-native-selection-records-native-build:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-native-selection-records-native $(filter-out main.swift,$(SOURCES)) ../test/event-stream-native-selection-records-native.swift

.PHONY: event-stream-native-selection-records-test event-stream-native-selection-records-native-build

SOURCES += EventStreamTerminalCapture.swift EventStreamRecorderObservation.swift

event-stream-terminal-test:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-terminal-tests $(filter-out main.swift,$(SOURCES)) ../test/event-stream-terminal.swift
	/tmp/cua-event-stream-terminal-tests

event-stream-recorder-observation-test:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-recorder-observation-tests $(filter-out main.swift,$(SOURCES)) ../test/event-stream-recorder-observation.swift
	/tmp/cua-event-stream-recorder-observation-tests

.PHONY: event-stream-terminal-test event-stream-recorder-observation-test

SOURCES += EventStreamFrontmostObservers.swift EventStreamRecorderLifecycle.swift EventStreamRecorderNotifications.swift

event-stream-recorder-lifecycle-test:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-recorder-lifecycle-tests $(filter-out main.swift,$(SOURCES)) ../test/event-stream-recorder-lifecycle.swift
	/tmp/cua-event-stream-recorder-lifecycle-tests

event-stream-recorder-notifications-test:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-recorder-notifications-tests $(filter-out main.swift,$(SOURCES)) ../test/event-stream-recorder-notifications.swift
	/tmp/cua-event-stream-recorder-notifications-tests

.PHONY: event-stream-recorder-lifecycle-test event-stream-recorder-notifications-test

SOURCES += EventStreamNativeRecorder.swift
SOURCES += ComputerUseTelemetryContext.swift EventStreamIPC.swift

event-stream-native-producer-test:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-native-producer-tests $(filter-out main.swift,$(SOURCES)) ../test/event-stream-native-producer.swift
	/tmp/cua-event-stream-native-producer-tests

event-stream-native-producer-native-build:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-native-producer-input-fixture ../test/InputFixture.swift
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-native-producer-native $(filter-out main.swift,$(SOURCES)) ../test/event-stream-native-producer-native.swift

.PHONY: event-stream-native-producer-test event-stream-native-producer-native-build

event-stream-recording-service-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-recording-service-tests EventStreamProtocol.swift EventStreamJSONLWriter.swift EventStreamCaptureCoordinator.swift EventStreamApplicationResolver.swift EventStreamURLPolicy.swift EventStreamRecordProcessor.swift EventStreamStorageConfiguration.swift EventStreamRecordingService.swift EventStreamRecordingWarning.swift ../test/event-stream-recording-service.swift
	/tmp/cua-event-stream-recording-service-tests

.PHONY: event-stream-recording-service-test

event-stream-recording-warning-native-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-recording-warning-live EventStreamProtocol.swift EventStreamApplicationResolver.swift EventStreamURLPolicy.swift EventStreamRecordingWarning.swift ../test/event-stream-recording-warning-native.swift
	python3 -c 'import subprocess,sys; sys.exit(subprocess.run(["/tmp/cua-recording-warning-live"], timeout=35).returncode)'

.PHONY: event-stream-recording-warning-native-test

event-stream-recording-overlay-native-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-recording-overlay-live EventStreamRecordingOverlay.swift ../test/event-stream-recording-overlay-native.swift
	python3 -c 'import subprocess,sys; sys.exit(subprocess.run(["/tmp/cua-recording-overlay-live"], timeout=20).returncode)'

.PHONY: event-stream-recording-overlay-native-test

event-stream-recording-status-native-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-recording-status-live EventStreamProtocol.swift EventStreamApplicationResolver.swift EventStreamURLPolicy.swift EventStreamRecordingStatusView.swift EventStreamRecordingWarning.swift EventStreamRecordingOverlay.swift EventStreamRecordingControls.swift ../test/event-stream-recording-status-native.swift
	python3 -c 'import subprocess,sys; sys.exit(subprocess.run(["/tmp/cua-recording-status-live"], timeout=25).returncode)'

.PHONY: event-stream-recording-status-native-test

event-stream-recording-url-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) $(TOML_FLAGS) -o /tmp/cua-event-stream-recording-url-tests EventStreamProtocol.swift EventStreamApplicationResolver.swift EventStreamURLPolicy.swift EventStreamJSONLWriter.swift EventStreamRecordProcessor.swift EventStreamRecordingURLPolicy.swift Configuration/AcuaConfiguration.swift Configuration/AcuaConfigurationLoader.swift Configuration/AcuaSettings.swift ../test/event-stream-recording-url.swift
	/tmp/cua-event-stream-recording-url-tests

.PHONY: event-stream-recording-url-test


native-pip-window-ownership-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-native-pip-window-ownership-tests RemoteHostedPIPWindowOwnership.swift ../test/native-pip-window-ownership.swift
	/tmp/cua-native-pip-window-ownership-tests ../test/native-pip-window-ownership-corpus.json

.PHONY: native-pip-window-ownership-test

native-pip-xpc-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-native-pip-xpc-tests RemoteHostedPIPXPC.swift ../test/native-pip-xpc.swift
	node ../test/native-pip-xpc.mjs ../test/native-pip-xpc-protocol-corpus.json

.PHONY: native-pip-xpc-test

computer-use-xpc-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-computer-use-xpc-test ComputerUseXPC.swift XPCSessionAdmission.swift ComputerUseXPCBootstrap.swift SenderAuthorization.swift AppleEventAuthorization.swift SenderRequestContext.swift Protocol.swift RemoteHostedPIPXPC.swift RemoteHostedPIPConnection.swift AsyncSerialQueue.swift RemoteHostedPIPContentPublisher.swift ../test/computer-use-xpc.swift
	python3 -c 'import subprocess,sys; sys.exit(subprocess.run(["/tmp/cua-computer-use-xpc-test"],timeout=15).returncode)'

.PHONY: computer-use-xpc-test

xpc-session-admission-test:
	python3 ../test/xpc-session-admission.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: xpc-session-admission-test

apple-event-authorization-test:
	python3 ../test/apple-event-authorization.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: apple-event-authorization-test

sender-client-metadata-test:
	python3 ../test/sender-client-metadata.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: sender-client-metadata-test

native-pip-connection-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-native-pip-connection-tests RemoteHostedPIPXPC.swift RemoteHostedPIPConnection.swift ../test/native-pip-connection.swift
	CUA_PIP_XPC_BINARY=/tmp/cua-native-pip-connection-tests node ../test/native-pip-xpc.mjs ../test/native-pip-connection-corpus.json

.PHONY: native-pip-connection-test

native-pip-producer-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-native-pip-producer-tests RemoteHostedPIPXPC.swift RemoteHostedPIPConnection.swift AsyncSerialQueue.swift RemoteHostedPIPContentPublisher.swift RemoteHostedPIPLayerContext.swift RemoteHostedPIPCheckerboardRenderer.swift RemoteHostedPIPContentStream.swift RemoteHostedPIPVideoEncoder.swift ../test/native-pip-producer.swift
	CUA_PIP_XPC_BINARY=/tmp/cua-native-pip-producer-tests node ../test/native-pip-xpc.mjs ../test/native-pip-producer-corpus.json

.PHONY: native-pip-producer-test

PIP_WINDOW_TEST_SOURCES = WindowDescription.swift RemoteHostedPIPXPC.swift RemoteHostedPIPConnection.swift AsyncSerialQueue.swift RemoteHostedPIPContentPublisher.swift RemoteHostedPIPLayerContext.swift RemoteHostedPIPCheckerboardRenderer.swift RemoteHostedPIPContentStream.swift RemoteHostedPIPVideoEncoder.swift RemoteHostedPIPWindowRenderer.swift RemoteHostedPIPWindowGeometryObserver.swift RemoteHostedPIPWindowServerObserver.swift WindowServerNotificationRequests.swift RemoteHostedPIPWindowFocus.swift ApplicationRegistrySPI.swift AccessibilityWindowSPI.swift Protocol.swift CursorMotionCompletion.swift

native-pip-window-build:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-native-pip-window-tests $(PIP_WINDOW_TEST_SOURCES) NativeMouseClick.swift CursorOverlay.swift CursorArtwork.swift ../test/native-pip-window.swift

.PHONY: native-pip-window-build

native-pip-focus-build:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-native-pip-focus-tests $(PIP_WINDOW_TEST_SOURCES) ../test/native-pip-focus.swift

.PHONY: native-pip-focus-build

native-window-server-order-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-native-window-server-order-tests RemoteHostedPIPWindowServerObserver.swift WindowServerNotificationRequests.swift ../test/native-window-server-order.swift
	python3 -c 'import subprocess,sys; sys.exit(subprocess.run(["/tmp/cua-native-window-server-order-tests"],timeout=12).returncode)'

.PHONY: native-window-server-order-test

native-pip-controller-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-native-pip-controller-tests $(PIP_WINDOW_TEST_SOURCES) RemoteHostedPIPWindowOwnership.swift RemoteHostedPIPController.swift ../test/native-pip-controller.swift
	/tmp/cua-native-pip-controller-tests

.PHONY: native-pip-controller-test

native-pip-layer-context-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-native-pip-layer-context-tests RemoteHostedPIPXPC.swift RemoteHostedPIPConnection.swift RemoteHostedPIPLayerContext.swift ../test/native-pip-layer-context.swift
	CUA_PIP_XPC_BINARY=/tmp/cua-native-pip-layer-context-tests node ../test/native-pip-xpc.mjs ../test/native-pip-layer-context-corpus.json

.PHONY: native-pip-layer-context-test

native-pip-checkerboard-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-native-pip-checkerboard-tests RemoteHostedPIPXPC.swift RemoteHostedPIPLayerContext.swift RemoteHostedPIPCheckerboardRenderer.swift ../test/native-pip-checkerboard-support.swift ../test/native-pip-checkerboard.swift
	/tmp/cua-native-pip-checkerboard-tests ../test/native-pip-checkerboard-corpus.json

.PHONY: native-pip-checkerboard-test

async-serial-queue-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-async-serial-queue-tests AsyncSerialQueue.swift ../test/async-serial-queue.swift
	/tmp/cua-async-serial-queue-tests

.PHONY: async-serial-queue-test

event-stream-telemetry-wire-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-telemetry-wire-tests EventStreamProtocol.swift ComputerUseTelemetryContext.swift ../test/event-stream-telemetry-wire.swift
	/tmp/cua-event-stream-telemetry-wire-tests ../test/event-stream-telemetry-wire-corpus.json

event-stream-ipc-native-build:
	$(SWIFTC) $(SWIFTFLAGS) $(LEGACY_FIXTURE_FLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-ipc-native $(filter-out main.swift,$(SOURCES)) ../test/event-stream-ipc-native.swift
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-event-stream-native-producer-input-fixture ../test/InputFixture.swift

.PHONY: event-stream-telemetry-wire-test event-stream-ipc-native-build

TIMELINE_SOURCES = TimelineProtocol.swift TimelineObservationNormalization.swift TimelineObservationMatching.swift TimelinePause.swift TimelineHistory.swift
SOURCES += $(TIMELINE_SOURCES)

timeline-wire-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-wire-tests $(TIMELINE_SOURCES) ../test/timeline-wire.swift
	/tmp/cua-timeline-wire-tests ../test/timeline-wire-corpus.json

.PHONY: timeline-wire-test

timeline-matching-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-matching-tests $(TIMELINE_SOURCES) ../test/timeline-matching.swift
	/tmp/cua-timeline-matching-tests ../test/timeline-matching-corpus.json

.PHONY: timeline-matching-test

timeline-pause-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-pause-tests $(TIMELINE_SOURCES) ../test/timeline-pause.swift
	/tmp/cua-timeline-pause-tests ../test/timeline-pause-corpus.json

.PHONY: timeline-pause-test

timeline-history-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-history-tests $(TIMELINE_SOURCES) ../test/timeline-history.swift
	/tmp/cua-timeline-history-tests ../test/timeline-history-corpus.json

.PHONY: timeline-history-test

timeline-history-interval-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-history-interval-tests $(TIMELINE_SOURCES) ../test/timeline-history-interval.swift
	/tmp/cua-timeline-history-interval-tests ../test/timeline-history-interval-corpus.json

.PHONY: timeline-history-interval-test

SOURCES += TimelineSegmentStore.swift

timeline-segment-store-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-segment-store-tests EventStreamProtocol.swift TimelineSegmentStore.swift ../test/timeline-segment-store.swift
	/tmp/cua-timeline-segment-store-tests ../test/timeline-segment-store-corpus.json

.PHONY: timeline-segment-store-test

SOURCES += TimelineSegmentWriter.swift

timeline-writer-initialization-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-writer-initialization-tests EventStreamProtocol.swift EventStreamJSONLWriter.swift TimelineSegmentStore.swift TimelineSegmentWriter.swift ../test/timeline-writer-fixtures.swift ../test/timeline-writer-initialization.swift
	/tmp/cua-timeline-writer-initialization-tests ../test/timeline-writer-initialization-corpus.json

.PHONY: timeline-writer-initialization-test

timeline-writer-lifecycle-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-writer-lifecycle-tests EventStreamProtocol.swift EventStreamJSONLWriter.swift TimelineSegmentStore.swift TimelineSegmentWriter.swift ../test/timeline-writer-fixtures.swift ../test/timeline-writer-lifecycle.swift
	/tmp/cua-timeline-writer-lifecycle-tests ../test/timeline-writer-lifecycle-corpus.json

.PHONY: timeline-writer-lifecycle-test

timeline-writer-clear-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-writer-clear-tests EventStreamProtocol.swift EventStreamJSONLWriter.swift TimelineSegmentStore.swift TimelineSegmentWriter.swift ../test/timeline-writer-fixtures.swift ../test/timeline-writer-clear.swift
	/tmp/cua-timeline-writer-clear-tests ../test/timeline-writer-clear-corpus.json

.PHONY: timeline-writer-clear-test

timeline-writer-append-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-writer-append-tests EventStreamProtocol.swift EventStreamJSONLWriter.swift TimelineSegmentStore.swift TimelineSegmentWriter.swift ../test/timeline-writer-fixtures.swift ../test/timeline-writer-append.swift
	/tmp/cua-timeline-writer-append-tests ../test/timeline-writer-append-corpus.json

.PHONY: timeline-writer-append-test

TIMELINE_SETTINGS_SOURCES = TimelineSettingsStorage.swift TimelineSettingsUpdateType.swift TimelineSettingsTelemetry.swift
SOURCES += $(TIMELINE_SETTINGS_SOURCES)

timeline-settings-storage-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-settings-storage-tests $(TIMELINE_SOURCES) $(TIMELINE_SETTINGS_SOURCES) ../test/timeline-writer-fixtures.swift ../test/timeline-settings-storage.swift
	/tmp/cua-timeline-settings-storage-tests ../test/timeline-settings-storage-corpus.json

.PHONY: timeline-settings-storage-test

timeline-settings-update-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-settings-update-tests $(TIMELINE_SOURCES) $(TIMELINE_SETTINGS_SOURCES) ../test/timeline-writer-fixtures.swift ../test/timeline-settings-update.swift
	/tmp/cua-timeline-settings-update-tests ../test/timeline-settings-update-corpus.json

.PHONY: timeline-settings-update-test

timeline-settings-policy-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-settings-policy-tests $(TIMELINE_SOURCES) $(TIMELINE_SETTINGS_SOURCES) ../test/timeline-writer-fixtures.swift ../test/timeline-settings-policy.swift
	/tmp/cua-timeline-settings-policy-tests ../test/timeline-settings-policy-corpus.json

.PHONY: timeline-settings-policy-test

timeline-settings-telemetry-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-settings-telemetry-tests $(TIMELINE_SOURCES) $(TIMELINE_SETTINGS_SOURCES) ../test/fixtures/AgentStructuredTelemetry.swift ../test/timeline-writer-fixtures.swift ../test/timeline-settings-telemetry.swift
	/tmp/cua-timeline-settings-telemetry-tests ../test/timeline-settings-telemetry-corpus.json

.PHONY: timeline-settings-telemetry-test

# Timeline lifecycle and real asynchronous record processing components.
TIMELINE_RUNTIME_SOURCES = TimelineLifecycle.swift TimelineResourcePreparation.swift TimelineLifecycleTelemetry.swift TimelineResumeScheduler.swift TimelineRecordProcessor.swift TimelinePrivateBrowsingIndicators.swift
SOURCES += $(TIMELINE_RUNTIME_SOURCES)
TIMELINE_RUNTIME_TEST_SOURCES = $(TIMELINE_SOURCES) $(TIMELINE_SETTINGS_SOURCES) $(TIMELINE_RUNTIME_SOURCES) EventStreamProtocol.swift EventStreamJSONLWriter.swift EventStreamCaptureCoordinator.swift EventStreamApplicationResolver.swift EventStreamURLPolicy.swift EventStreamRecordProcessor.swift EventStreamStorageConfiguration.swift EventStreamRecordingService.swift TimelineSegmentStore.swift TimelineSegmentWriter.swift

timeline-lifecycle-stopped-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-lifecycle-stopped-tests $(TIMELINE_RUNTIME_TEST_SOURCES) ../test/timeline-lifecycle-stopped.swift
	/tmp/cua-timeline-lifecycle-stopped-tests ../test/timeline-lifecycle-stopped-corpus.json

.PHONY: timeline-lifecycle-stopped-test

timeline-lifecycle-paused-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-lifecycle-paused-tests $(TIMELINE_RUNTIME_TEST_SOURCES) ../test/fixtures/AgentStructuredTelemetry.swift ../test/timeline-lifecycle-paused.swift
	/tmp/cua-timeline-lifecycle-paused-tests ../test/timeline-lifecycle-paused-corpus.json

.PHONY: timeline-lifecycle-paused-test

timeline-resume-scheduler-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-resume-scheduler-tests $(TIMELINE_RUNTIME_TEST_SOURCES) ../test/timeline-resume-scheduler.swift
	/tmp/cua-timeline-resume-scheduler-tests

.PHONY: timeline-resume-scheduler-test

timeline-record-processing-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-record-processing-tests $(TIMELINE_RUNTIME_TEST_SOURCES) ../test/timeline-record-processing.swift
	/tmp/cua-timeline-record-processing-tests ../test/timeline-record-processing-corpus.json

.PHONY: timeline-record-processing-test

SOURCES += TimelineMemorySummaryStore.swift

timeline-memory-storage-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-memory-storage-tests TimelineMemorySummaryStore.swift ../test/timeline-memory-fixtures.swift ../test/timeline-memory-storage.swift
	/tmp/cua-timeline-memory-storage-tests ../test/timeline-memory-storage-corpus.json

.PHONY: timeline-memory-storage-test

TIMELINE_MEMORY_SOURCES = TimelineMemorySummaryStore.swift TimelineMemoryPipeline.swift TimelineMemoryRollupWindows.swift TimelineMemorySlug.swift TimelineMemorySummaryWriter.swift TimelineSummaryError.swift TimelineSummaryReader.swift
SOURCES += $(filter-out TimelineMemorySummaryStore.swift,$(TIMELINE_MEMORY_SOURCES))
SOURCES += TimelineHistoryAvailability.swift TimelineService.swift TimelineOperation.swift TimelineIPC.swift
SOURCES += MessagesWire.swift MessagesReadValidation.swift MessagesPaging.swift MessagesAttributedBody.swift
SOURCES += MessagesImageProcessor.swift MessagesImageRead.swift MessagesAttachmentStore.swift MessagesReadPage.swift MessagesIPC.swift
SOURCES += MessagesChatDiscovery.swift MessagesActivity.swift
SOURCES += MessagesSendPlans.swift MessagesSendTargets.swift MessagesSendFiles.swift MessagesDelivery.swift
MESSAGES_TEST_SUPPORT = Protocol.swift RequestRuntime.swift SenderRequestContext.swift PendingResult.swift AsyncSerialQueue.swift UserInteraction.swift

messages-read-image-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-messages-read-image-test $(filter Messages%.swift,$(SOURCES)) $(MESSAGES_TEST_SUPPORT) ../test/messages-read-image.swift
	/tmp/cua-messages-read-image-test

messages-read-page-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-messages-read-page-test $(filter Messages%.swift,$(SOURCES)) $(MESSAGES_TEST_SUPPORT) ../test/messages-read-page.swift
	/tmp/cua-messages-read-page-test

messages-chat-discovery-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-messages-chat-discovery-test $(filter Messages%.swift,$(SOURCES)) $(MESSAGES_TEST_SUPPORT) ../test/messages-chat-discovery.swift
	/tmp/cua-messages-chat-discovery-test

messages-send-plans-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-messages-send-plans-test $(filter Messages%.swift,$(SOURCES)) $(MESSAGES_TEST_SUPPORT) ../test/messages-send-plans.swift
	/tmp/cua-messages-send-plans-test
CALENDAR_SOURCES = CalendarWire.swift CalendarPaging.swift CalendarEventKitReads.swift CalendarEventKitWrites.swift CalendarRecurrence.swift CalendarOperation.swift CalendarIPC.swift
SOURCES += $(CALENDAR_SOURCES)

.PHONY: calendar-service-test
calendar-service-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-calendar-service-test Protocol.swift PendingResult.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift AsyncSerialQueue.swift $(CALENDAR_SOURCES) ../test/calendar-service.swift
	/tmp/cua-calendar-service-test

timeline-service-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-timeline-service-tests Protocol.swift $(TIMELINE_RUNTIME_TEST_SOURCES) $(TIMELINE_MEMORY_SOURCES) TimelineHistoryAvailability.swift TimelineService.swift TimelineOperation.swift ../test/timeline-service.swift
	/tmp/cua-timeline-service-tests

.PHONY: timeline-service-test

# The extra dispatch endpoint exists only in a generated temporary test main.
NATIVE_AUTOMATION_HARNESS ?= /tmp/cua-native-automation-harness/AexComputerUseService
native-automation-harness-build:
	python3 ../test/build-native-automation-harness.py --output $(NATIVE_AUTOMATION_HARNESS) --swiftflags="$(SWIFTFLAGS)"

native-automation-test: native-automation-harness-build
	CUA_NATIVE_AUTOMATION_HARNESS=$(NATIVE_AUTOMATION_HARNESS) node ../test/native-automation.mjs

native-web-form-test: native-automation-harness-build
	CUA_NATIVE_AUTOMATION_HARNESS=$(NATIVE_AUTOMATION_HARNESS) node ../test/native-web-form.mjs

native-hosted-panel-test: native-automation-harness-build
	CUA_NATIVE_AUTOMATION_HARNESS=$(NATIVE_AUTOMATION_HARNESS) node ../test/native-hosted-panel.mjs

native-deep-hierarchy-test: native-automation-harness-build
	CUA_NATIVE_AUTOMATION_HARNESS=$(NATIVE_AUTOMATION_HARNESS) node ../test/native-deep-hierarchy.mjs

ax-parent-chain-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-ax-parent-chain-tests AXParentChain.swift ../test/ax-parent-chain.swift
	/tmp/cua-ax-parent-chain-tests

# Real fixture actions with a controlled AX API status, compiled only in the
# temporary test main/source tree. No injection switch is in the product.
native-press-error-test:
	python3 ../test/build-native-automation-harness.py --output /tmp/cua-native-press-error-harness/AexComputerUseService --swiftflags="$(SWIFTFLAGS)" --ax-press-error-probe
	CUA_NATIVE_AUTOMATION_HARNESS=/tmp/cua-native-press-error-harness/AexComputerUseService CUA_NATIVE_PRESS_ERROR_PROBE=1 node ../test/native-automation.mjs

element-validation-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-element-validation-tests EventStreamPartialValue.swift EventStreamTransformedValue.swift EventStreamPresentation.swift EventStreamTransformedString.swift EventStreamTransformedNode.swift EventStreamElementValidation.swift ../test/event-stream-element-validation.swift
	/tmp/cua-element-validation-tests

.PHONY: native-automation-harness-build native-automation-test native-web-form-test native-hosted-panel-test native-deep-hierarchy-test ax-parent-chain-test native-press-error-test element-validation-test

# Controlled asynchronous dependency: no account or network access.
native-url-policy-thread-test:
	python3 ../test/build-native-automation-harness.py --output /tmp/cua-native-url-policy-harness/AexComputerUseService --swiftflags="$(SWIFTFLAGS)" --url-policy-probe
	CUA_NATIVE_AUTOMATION_HARNESS=/tmp/cua-native-url-policy-harness/AexComputerUseService node ../test/native-url-policy-thread.mjs

.PHONY: native-url-policy-thread-test

audio-shutdown-phases-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-audio-shutdown-phases-tests Protocol.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift PendingResult.swift AudioRequest.swift AudioCaptureBridge.swift Audio.swift ../test/audio-shutdown-phases.swift
	/tmp/cua-audio-shutdown-phases-tests /tmp/cua-audio-shutdown-phases-result.json ../test/audio-shutdown-phases-expected.json

.PHONY: audio-shutdown-phases-test

audio-start-suspension-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-audio-start-suspension-tests Protocol.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift PendingResult.swift AudioRequest.swift AudioCaptureBridge.swift Audio.swift ../test/audio-start-suspension.swift
	/tmp/cua-audio-start-suspension-tests /tmp/cua-audio-start-suspension-result.json ../test/audio-start-suspension-expected.json

.PHONY: audio-start-suspension-test

audio-unclaimed-expiry-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-audio-unclaimed-expiry-tests Protocol.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift PendingResult.swift AudioRequest.swift AudioCaptureBridge.swift Audio.swift ../test/audio-unclaimed-expiry.swift
	/tmp/cua-audio-unclaimed-expiry-tests /tmp/cua-audio-unclaimed-expiry-result.json ../test/audio-unclaimed-expiry-expected.json

.PHONY: audio-unclaimed-expiry-test

audio-native-start-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-audio-native-start-tests Protocol.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift PendingResult.swift AudioRequest.swift AudioCaptureBridge.swift Audio.swift ../test/audio-native-harness.swift ../test/audio-native-start.swift
	/tmp/cua-audio-native-start-tests /tmp/cua-audio-native-start-result.json ../test/audio-native-start-expected.json

audio-prepared-deadline-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-audio-prepared-deadline-tests Protocol.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift PendingResult.swift AudioRequest.swift AudioCaptureBridge.swift Audio.swift ../test/audio-native-harness.swift ../test/audio-prepared-deadlines.swift
	/tmp/cua-audio-prepared-deadline-tests /tmp/cua-audio-prepared-deadline-result.json

.PHONY: audio-native-start-test audio-prepared-deadline-test

audio-pcm-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-audio-pcm-tests Protocol.swift AppSessions.swift RequestRuntime.swift SenderRequestContext.swift PendingResult.swift AudioRequest.swift AudioCaptureBridge.swift Audio.swift ../test/audio-native-harness.swift ../test/audio-pcm-buffers.swift ../test/audio-pcm.swift
	/tmp/cua-audio-pcm-tests /tmp/cua-audio-pcm-result.json ../test/audio-pcm-expected.json

.PHONY: audio-pcm-test

markdown-html-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-markdown-html-tests Protocol.swift MarkdownHTML.swift ../test/markdown-html.swift
	/tmp/cua-markdown-html-tests ../test/markdown-html-corpus.json /tmp/cua-markdown-html-result.json

.PHONY: markdown-html-test

offscreen-spi-test:
	python3 ../test/offscreen-spi.py --swiftflags="$(SWIFTFLAGS)"

.PHONY: offscreen-spi-test

async-queue-lifecycle-test:
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) -o /tmp/cua-async-queue-lifecycle-tests AsyncSerialQueue.swift ../test/async-queue-lifecycle.swift
	/tmp/cua-async-queue-lifecycle-tests ../test/async-queue-lifecycle-expected.json /tmp/cua-async-queue-lifecycle-result.json

.PHONY: async-queue-lifecycle-test

native-click-web-test:
	python3 ../test/native-click-web.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: native-click-web-test

native-mouse-click-test:
	python3 ../test/native-mouse-click.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: native-mouse-click-test

native-click-focus-test: focus-installation-test
	python3 ../test/native-click-focus.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: native-click-focus-test

focus-installation-test:
	python3 ../test/focus-installation.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: focus-installation-test

coordinate-click-test:
	python3 ../test/coordinate-click.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"
	python3 ../test/native-pointer-sender.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"
	python3 ../test/pointer-target-context.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"
	python3 ../test/pointer-window-registry.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"
	python3 ../test/typed-menu-registry.py
	python3 ../test/pointer-movement-event.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: coordinate-click-test

system-settings-appearance-test:
	python3 ../test/system-settings-appearance.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: system-settings-appearance-test

settings-accessory-test:
	python3 ../test/settings-accessory.py --swiftc "$(SWIFTC)" --swiftflags="$(SWIFTFLAGS)"

.PHONY: settings-accessory-test

settings-accessory-native-test:
	python3 ../test/settings-accessory-native.py --swiftflags="$(SWIFTFLAGS)" --async-check

.PHONY: settings-accessory-native-test

window-server-notification-requests-test:
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors $(DEPLOYMENT_FLAGS) -module-cache-path $(SWIFT_MODULE_CACHE) WindowServerNotificationRequests.swift ../test/window-server-notification-requests.swift -o /private/tmp/cua-window-server-requests-tests
	/private/tmp/cua-window-server-requests-tests /private/tmp/cua-window-server-requests-result.json

.PHONY: window-server-notification-requests-test


screen-lock-state-test:
	python3 ../test/screen-lock-state.py --swiftflags="$(SWIFTFLAGS)"

.PHONY: screen-lock-state-test


permission-catalogue-registry-test:
	python3 ../test/permission-catalogue-registry.py --swiftflags="$(SWIFTFLAGS)" --native-objects

.PHONY: permission-catalogue-registry-test


service-permissions-test:
	python3 ../test/service-permissions.py --swiftflags="$(SWIFTFLAGS)"

.PHONY: service-permissions-test
