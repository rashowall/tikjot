import Testing

/// Root of the hosted app tests. Serialized as a whole: snapshot tests freeze the app-wide `Clock`,
/// which must never overlap with model tests that rely on the real time.
@Suite(.serialized) struct AppTestSuite {}
