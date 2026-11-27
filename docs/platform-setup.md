# Platform setup

Bluetooth needs permissions on every phone platform. The [example app](../example)
has all of these in place.

## Android

`minSdk` 21 or higher. In `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<!-- Android 11 and lower -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
```

Call `TalkaNote.requestPermissions()` before scanning.

## iOS

Deployment target 13.1 or higher. In `ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Connects to your talkaNote card to read and transfer recordings.</string>
```

To keep receiving while the app is in the background, also add
`bluetooth-central` to `UIBackgroundModes`.

iOS gives each card a UUID instead of a MAC address, and the UUID differs per
phone. Save `DiscoveredCard.id` per device.

## macOS

Deployment target 10.15 or higher. Add to `macos/Runner/Info.plist` the same
`NSBluetoothAlwaysUsageDescription` as iOS, and to both
`DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.device.bluetooth</key>
<true/>
```

## Windows

Windows 10 or later with Bluetooth LE. No permissions needed. Building a Flutter
app with plugins on Windows needs **Developer Mode** turned on
(`start ms-settings:developers`).

## Simulators

Bluetooth doesn't work in the iOS simulator or the Android emulator. Test on
real devices.
