# Accessibility quality gate

NativeContainers treats accessibility as a release contract, not as a property
inferred from using SwiftUI. Source checks prevent known structural regressions;
an exact signed build must still complete the live matrix before release.

## Source contract

Management UI must satisfy these rules:

- Activation uses semantic `Button`, `Toggle`, `Picker`, `Menu`, `Link`, or
  another standard control. A tap gesture is never the only way to invoke an
  action.
- A row-selection button and its runtime or destructive actions are sibling
  controls. Selecting a resource must not consume the action controls, and each
  control must be independently keyboard reachable.
- Selectable rows expose their selected state as an accessibility value. A
  resource's visible name remains a valid input label for Voice Control and
  Full Keyboard Access.
- Icon-only controls retain a semantic control title or provide an explicit,
  localized accessibility label. Color and icon shape are not the only state
  indicators.
- Layout uses leading and trailing semantics rather than fixed left and right
  alignment. User-facing strings remain in the String Catalog.
- Stable domain identity, not a collection offset, identifies repeated
  management controls.
- Virtual-disk growth uses a labeled capacity field with an explicit GiB input
  label, a semantic Grow button, a destructive confirmation, visible progress,
  and text that communicates both the irreversible grow-only rule and required
  guest partition/filesystem follow-up without relying on color.

Run the repeatable source gate from the repository root:

```sh
scripts/validate-accessibility-contract.sh
```

The script rejects raw tap activation in management views, fixed directional
alignment, nonsemantic selection rows, loss of the VM-name input label or
selection value, localization-setting drift, and documentation drift. It does
not inspect the runtime accessibility tree, prove focus order, review a
translation, or replace testing with assistive technologies.

## Live test setup

Record the app commit, signed build identity, macOS and hardware versions,
locale, appearance, display settings, and test data. Populate every resource
category with both normal and error/empty states. Use the exact release
candidate; Preview evidence is supplementary.

For every workflow below, complete all of these passes:

1. **VoiceOver:** Traverse the window and each modal in order. Verify unique
   name, role, value/state, hint where needed, enabled state, action names,
   selection changes, progress/error announcements, and return focus after
   dismissal. Decorative content must not add noise.
2. **Full Keyboard Access:** Reach every control with forward and reverse
   traversal. Activate buttons and rows with Space or Return, operate menus and
   pickers, cancel with Escape, and verify that sheets, popovers, consoles, and
   terminal tabs neither trap nor lose focus. Row selection and row actions
   must be separate stops.
3. **Voice Control:** Show names and numbers, then invoke every visible resource
   and action by its displayed or documented alternate name. Dynamic resource
   names must remain speakable.
4. **Visual settings:** Repeat the critical path with Increase Contrast,
   Differentiate Without Color, Reduce Transparency, Reduce Motion, and a
   larger display/text configuration. Verify clipping, state distinction,
   focus indication, and motion alternatives.
5. **Localization:** Exercise the source language, a pseudolanguage, and each
   reviewed shipping translation. Verify truncation, pluralization, command
   shortcuts, spoken labels, and that destructive wording preserves meaning.

## Workflow matrix

Each row requires an evidence record and a named reviewer. `Open` means the
live gate is not yet satisfied, even when its source structure has passed.

| Workflow | Representative coverage | Live evidence |
| --- | --- | --- |
| App shell and navigation | Sidebar, toolbar, Overview cards, Command-K Quick Open, Command-0 through Command-9, refresh, notifications, window restoration | Open |
| Containers | List selection versus action menu, create/review, inspect, stats, logs, exec, copy, terminal, ports, host folders, volumes, networks, sockets, SSH agent, stop/restart/Force Stop/delete | Open |
| Images, registry, and builds | Pull/push/tag/delete/prune, login/logout, build review, outputs, secrets, local/registry cache, active progress, history, cancellation and errors | Open |
| Volumes, networks, and storage | Create/delete/prune, in-use states, accounting refresh, reclamation review, destructive confirmation and partial results | Open |
| Persistent Linux machines | Create, first-user setup, selection versus tools, configuration, start/stop/Force Stop/delete, command runner and terminal | Open |
| Compose | Project discovery, reviewed Up/Down, scale/start/stop, recovery records, external-resource warnings and locked navigation | Open |
| Kubernetes | Cluster setup/lifecycle/delete/export, workload/pod/service browser, search, scale/restart/delete review, Pod logs, one-shot commands, and terminal tabs | Open |
| GUI Linux virtual machines | ISO selection/copy, create, selection versus runtime actions, install console, rename, compute/network/disk-growth configuration, shared folders, pause/resume/suspend/restore/Start Fresh/Discard Saved State/shutdown/Force Stop/eject, clone, export/import and delete | Open |
| macOS virtual machines | IPSW download/import, prepare/install, selection versus runtime actions, console, saved state, rename, compute, grow/convert/rewrite disk, disk snapshots, shares, audio, network, USB, clone, export/import and delete | Open |
| Settings and optional integrations | App behavior, menu-bar controls, Docker compatibility, diagnostics export/delete, performance baselines, cancellation and unavailable states | Open |
| Cross-workflow presentation | Empty/loading/error states, sheets, popovers, confirmation dialogs, file panels, help, keyboard focus restoration and reduced-motion transitions | Open |

## Evidence record

A passing record contains:

- exact commit and signed app identity;
- tester, date, OS, hardware, locale, and assistive-technology settings;
- fixture identities and workflow row;
- pass/fail result for every pass above;
- issue links and focused screenshots or recordings for failures;
- confirmation that every issue was retested on the final commit.

The release gate closes only when every matrix row has reviewed evidence for
VoiceOver and Full Keyboard Access, no critical Voice Control or visual-settings
defect remains, and every shipping translation has language-owner approval.

Apple references: [Accessibility Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/accessibility/),
[SwiftUI accessible descriptions](https://developer.apple.com/documentation/swiftui/accessible-descriptions),
and [SwiftUI accessibility modifiers](https://developer.apple.com/documentation/swiftui/view-accessibility).
