# Developer Tools

These tools are manually run diagnostics and regression harnesses. They are not
part of the Mos app target.

- `hidpp/`: Logitech HID++ probing, divert, undivert, and verification scripts.
- `regression/`: small standalone regression harnesses that compile selected app
  components outside the full Xcode test target.
- `trackpad/`: opt-in three/four-finger tap probe, copy/paste trial, and isolated tests.
  See [trackpad/README.md](trackpad/README.md) for build and device verification.

Run scripts from the repository root unless a script says otherwise.
