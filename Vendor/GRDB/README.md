# Vendored GRDB.swift (SQLCipher build)

GRDB.swift **v7.11.1** by Gwendal Roué, MIT licensed (see `LICENSE`).
SwiftPM can't switch GRDB to SQLCipher without editing its manifest, so the library
sources are vendored here with the official "GRDB+SQLCipher" manifest changes applied.

Updating: download the new tag, replace `GRDB/` and `Sources/GRDBSQLCipher/`, keep this `Package.swift`
(bump the SQLCipher.swift version to the one GRDB's manifest names).
