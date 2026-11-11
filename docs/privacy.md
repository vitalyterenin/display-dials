# Privacy and network activity

From version 0.6.10, Display Dials does not collect or send usage statistics.
The app has no analytics transport, event queue, installation identifier or
statistics consent window.
The app privacy manifest declares no collected data and no tracking.

Night Shift controls and the local `--status` diagnostic work on the Mac. The
status command uses local distributed notifications; it does not contact a server.

Option–Command–N registers one global shortcut using macOS hot-key registration;
the app does not monitor or record general keyboard input. Switching light/dark
appearance runs Apple's local `osascript` tool against System Events and requires
Automation permission. It reads and changes only the appearance's `dark mode`
property. This permission is requested only when you invoke the action.

Sparkle requests the signed update feed from this repository's GitHub Pages site
and downloads updates from its GitHub Releases. Automatic update checks and
installation can be changed in **More options (…) > Updates**. Sparkle system
profiling is disabled.
These network requests expose the connection's IP address to the hosting service.

Removing statistics support does not delete data received by the former service
from older versions. Existing installations must run a build containing this
removal to stop using the old implementation.
