# Proto instructions

Keep each `.proto` schema paired with its generated `.pb.swift` file. Regenerate or update both together when the wire schema changes; schemas are excluded from the Swift target in `Package.swift`.
