# TestSupport instructions

Shared test helpers provide temporary directories and condition polling. Prefer `pollUntil`/`waitUntil` with a timeout over fixed `Task.sleep` delays.
