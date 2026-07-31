<p align="right">
  <a href="./README.md">简体中文</a> · <strong>English</strong>
</p>

# Wujian

<div align="center">
  <p><strong>A mobile workflow that connects capture, AI recognition, and searchable inventory.</strong></p>
  <p>
    <a href="https://flutter.dev/"><img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter"></a>
    <a href="https://dart.dev/"><img alt="Dart" src="https://img.shields.io/badge/Dart-%5E3.9.2-0175C2?logo=dart"></a>
    <img alt="Version" src="https://img.shields.io/badge/version-1.0.4-7C3AED">
    <a href="./LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-22C55E"></a>
  </p>
  <p>
    <a href="#quick-start">Quick Start</a> ·
    <a href="#capabilities">Capabilities</a> ·
    <a href="#architecture">Architecture</a> ·
    <a href="./docs/releases/v1.0.4.md">v1.0.4 Release Notes (Chinese)</a>
  </p>
</div>

> Current version: `1.0.4+5`. Wujian is a runnable Flutter application under active iteration, with Android and iOS maintained from the same codebase.

## Product preview

| Capture and recovery queue | Inventory records | Model settings |
| --- | --- | --- |
| ![Capture and recovery queue](https://caoyueyang.org/images/work/wujian/capture-queue.webp) | ![Inventory records](https://caoyueyang.org/images/work/wujian/inventory-view.webp) | ![Model settings](https://caoyueyang.org/images/work/wujian/model-settings.webp) |

## Why Wujian

Photo libraries preserve images, but they are not designed to answer questions such as “What is this?”, “Where did I put it?”, or “When did I buy it?” Wujian turns each capture into a recoverable task, sends it to a user-selected vision model for structured extraction, and stores the confirmed result in a local inventory.

Typical uses include:

- documenting items at home, in a studio, or in a small warehouse;
- building a structured inventory from photos;
- preserving queued work when a network or model provider becomes unavailable;
- choosing an OpenAI-compatible provider instead of depending on a single vendor.

## Capabilities

| Area | Current implementation |
| --- | --- |
| Capture and import | Camera capture, image selection, preprocessing, and local persistence |
| AI recognition | Preset providers and configurable OpenAI-compatible endpoints |
| Recovery queue | Observable task states, interrupted-task recovery, concurrency limits, and network safeguards |
| Inventory management | Structured records, categories, search, and statistics |
| Local data | Original images and inventory data are stored primarily on the device |
| Export | PDF, Excel, and Markdown export services |
| Cross-platform delivery | Shared Flutter project for Android and iOS |

## Quick start

### Prerequisites

- A Flutter SDK compatible with the constraint in `pubspec.yaml`;
- Dart `^3.9.2`;
- Android Studio or Xcode;
- a simulator, emulator, or physical device;
- access to at least one compatible vision-model service and its API key.

### Run the application

```bash
git clone https://github.com/GreatAndyC/Wujian_Flutter.git
cd Wujian_Flutter
flutter pub get
flutter run
```

Confirm the local toolchain and available devices with:

```bash
flutter doctor
flutter devices
```

### Configure an AI provider

Open Model Settings in the application and select a preset provider or enter an OpenAI-compatible custom endpoint. API keys are stored locally through the application and must never be committed to source control or exposed in screenshots and logs.

Model availability, pricing, quotas, and data-processing policies vary by provider. Review the provider's current documentation before sending sensitive images.

## Workflow

```mermaid
flowchart LR
    A["Capture or import a photo"] --> B["Preprocess locally"]
    B --> C["Enter the recoverable task queue"]
    C --> D["Call the configured vision model"]
    D --> E["Parse a structured draft"]
    E --> F["Human confirmation"]
    F --> G["Persist the local inventory record"]
    G --> H["Search, export, and maintain"]
```

The recovery queue is part of the main product flow. Interrupted `processing` items are re-queued on the next launch, and failed requests retain enough state to prevent a transient network error from discarding an entire capture batch.

## Architecture

The codebase separates UI, state coordination, domain contracts, persistence, model access, and platform services:

```text
lib/
├── app/            # Application shell and theme
├── features/       # Capture, inventory, settings, and navigation flows
├── domain/         # Entities and repository contracts
├── data/           # Local repositories, AI access, media, and export services
└── shared/         # Reusable widgets
```

The implementation includes content-hash image deduplication, background image compression, atomic catalog persistence with backup recovery, secure local credential storage, and a bounded recognition concurrency limit.

## Data and privacy

- Inventory records and source images are stored primarily on the device.
- Images and request content leave the device only when recognition is sent to the provider selected by the user.
- Wujian does not make retention, training-use, or compliance promises on behalf of third-party providers.
- Uninstalling the application can remove local data; back up important records before an upgrade or reinstall.
- Release builds must not contain real API keys, test accounts, or sensitive debug logs.

## Development and verification

```bash
flutter analyze
flutter test
flutter build apk
```

The GitHub release workflow runs static analysis and tests before producing signed Android release artifacts. Changes involving the camera, photo library, secure storage, network transitions, or recovery behavior also require Android and iOS device validation.

Automated tests cover interrupted queue recovery, duplicate imports, persistence rollback, settings rollback, image migration and deduplication, bounded recognition concurrency, local repositories, media storage, model responses, and widget behavior.

## Android signing note

Some early Android builds used a different debug signature and cannot be upgraded in place to a production-signed build. Back up important data before uninstalling an older version, because uninstalling removes the application's local directory and images.

## Project status

Current development priorities include:

- improving long-queue behavior and weak-network recovery;
- refining image storage, deduplication, and storage statistics;
- simplifying the provider adapter and structured-output path;
- expanding automated coverage for critical local-data workflows.

See the [v1.0.4 release notes](./docs/releases/v1.0.4.md) for the latest detailed changes. The release notes are currently maintained in Chinese.

## Contributing

Issues with clear reproduction steps and focused improvement proposals are welcome. Before submitting code, keep the change scoped and include the relevant automated tests or manual verification notes.

## License

Wujian is available under the [MIT License](./LICENSE).
