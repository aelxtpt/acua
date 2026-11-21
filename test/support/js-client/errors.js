export const ServerErrorCode = {
  senderProcessNotAuthenticated: -10000,
  couldNotGetRequestData: -10001,
  couldNotGetRequestTypeName: -10002,
  couldNotResolveRequestType: -10003,
  unhandledEvent: -10004,
  unknownError: -10005,
  appNotAllowed: -10006,
  runningApplicationNotFound: -10007,
  accessibilityError: -10008,
  permissionsNotGranted: -10009,
  invalidApp: -10010,
  noActiveSession: -10011,
  userStoppedSession: -10012,
  incompatibleClientVersion: -10013,
  permissionsPending: -10014,
  blockedURL: -10015,
  userIntervened: -10016,
  couldNotGetSenderPID: -10017,
  ambiguousApp: -10018,
  couldNotGetBootstrapPort: -10019,
  screenLocked: -10020,
};
const codeToName = new Map(Object.entries(ServerErrorCode).map(([name, code]) => [code, name]));
export class AexComputerUseError extends Error {
  constructor({ code, message, request, requestType }) {
    super(message);
    this.name = "AexComputerUseError";
    this.code = code;
    this.errorName = codeToName.get(code) ?? "jsonRPCError";
    this.request = request;
    this.requestType = requestType;
  }
}
export class AexComputerUseTransportError extends Error {
  constructor(message, { cause } = {}) {
    super(message);
    this.name = "AexComputerUseTransportError";
    this.cause = cause;
  }
}
