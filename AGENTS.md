# Apple Aerial Controller

Native Swift menu bar app for Apple Silicon, macOS 26 and one built-in display. Reuse locally downloaded Apple Aerial resources; do not add Apple media, user configuration, backups or build products to the repository.

## Code Review Rules

### Wallpaper ownership and recovery

- Flag native Wallpaper Store writes that bypass the existing structure, display-scope, ownership or external-change checks. Preserve the backup made before first takeover and abort writes when the source configuration changes; otherwise the app can overwrite the user's newer wallpaper choice or lose recovery data.
- Keep system mutations within the existing user-level adapter. Do not disable SIP or modify protected system files.

### Playback and asynchronous work

- Preserve the visible frame until the replacement is ready. Respect cancellation and session validation so late preparation or resume callbacks cannot restore a stopped player after stop, sleep or quit. Validate asynchronous native-switch results before updating app state; playback cancellation alone does not undo an in-flight native write.
- Pause and resume must retain the same playback position. Automatic rotation must skip deadlines while playback is active or paused, so it does not interrupt a video; manual previous/next remains allowed.
- Consume previous-selection history only after a successful switch. A failed switch must leave the history available for retry.

### Compatibility and validation

- Keep desktop playback and Apple lock-screen playback documented as separate timelines. Do not claim seamless native synchronization or support for other displays/system versions without evidence.
- Use the build/check scripts with a compatible Swift compiler and SDK. Tests requiring Apple manifests, Wallpaper Store or an AppKit session must state those prerequisites; model checks are not evidence of real video decoding or visual smoothness.
